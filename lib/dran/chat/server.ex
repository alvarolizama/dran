defmodule Dran.Chat.Server do
  @moduledoc """
  GenServer backing a single chat conversation.

  Each conversation is identified by (context_id, user) and persisted to
  `Dran.Chat.Session`. The server keeps the last 20 messages in memory
  and persists the same 20 to the database on every turn.

  ## Copilot agent + fallback

  When a message arrives, the server first tries the full agent loop
  (`Dran.Agent.Copilot`) which uses the `Agent.Engine` ReAct loop with
  all 18 MCP tools via native tool-calling. The engine runs asynchronously
  — `run/3` returns `{:ok, session}` immediately while the loop runs in
  a `Task.Supervisor` task. The server polls the session in the database
  until it reaches a terminal status (`done` / `failed` / `cancelled`)
  or a timeout fires.

  If the agent loop fails for any reason (exception, timeout, failed or
  cancelled status), the server falls back to `Dran.Chat.Brain.answer/4`
  (simple RAG) so the user always gets a reply.

  ## Lifecycle

  Started via `Dran.Chat.Supervisor.find_or_start/2` (DynamicSupervisor +
  Registry). `restart: :temporary` — if the process dies it is not
  automatically restarted; the next `find_or_start` will reload from DB.

  ## API

  - `send_message(pid, text)` → `{:ok, reply, sources}`
  - `history(pid)` → list of message maps
  - `clear(pid)` → `:ok
  """

  use GenServer, restart: :temporary

  alias Dran.Agent.Copilot
  alias Dran.Agent.Session, as: AgentSession
  alias Dran.Chat.{Brain, Session}
  alias Dran.Repo

  require Logger

  @max_messages 20
  # Poll interval for waiting on the async agent session.
  @agent_poll_interval_ms 200
  # How long to wait for the agent loop to finish before falling back.
  @agent_timeout_ms 120_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Start a chat server for a given context and user.

  Options:
  - `:context_id` (required) — the context UUID
  - `:user` (required) — the user identifier string
  - `:page_slug` — optional, the page the user is currently viewing
  """
  def start_link(opts) do
    context_id = Keyword.fetch!(opts, :context_id)
    user = Keyword.fetch!(opts, :user)
    page_slug = Keyword.get(opts, :page_slug)
    name = Keyword.get(opts, :name)

    init_arg = %{
      context_id: context_id,
      user: user,
      page_slug: page_slug,
      sandbox_owner: opts[:sandbox_owner]
    }

    if name do
      GenServer.start_link(__MODULE__, init_arg, name: name)
    else
      GenServer.start_link(__MODULE__, init_arg)
    end
  end

  @doc "Send a message and get a reply with sources"
  @spec send_message(pid(), String.t()) :: {:ok, String.t(), [map()]} | {:error, term()}
  def send_message(pid, text) do
    GenServer.call(pid, {:send_message, text}, 60_000)
  end

  @doc "Get the current message history"
  @spec history(pid()) :: [map()]
  def history(pid) do
    GenServer.call(pid, :history)
  end

  @doc "Clear the conversation history"
  @spec clear(pid()) :: :ok
  def clear(pid) do
    GenServer.call(pid, :clear)
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────

  @impl true
  def init(%{context_id: context_id, user: user, page_slug: page_slug} = args) do
    # Allow the GenServer's process to use the sandbox (shared mode in tests)
    maybe_allow_sandbox(args[:sandbox_owner])

    session = load_or_create_session(context_id, user, page_slug)
    messages = session.messages["items"] || []

    {:ok,
     %{
       context_id: context_id,
       user: user,
       page_slug: page_slug,
       session: session,
       messages: messages
     }}
  end

  @impl true
  def handle_call({:send_message, text}, _from, state) do
    user_msg = %{
      "role" => "user",
      "content" => text,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {reply, sources} =
      case run_copilot(state, text) do
        {:ok, summary, agent_sources} ->
          {summary, agent_sources}

        {:error, reason} ->
          Logger.warning(
            "Chat.Server: copilot agent failed (#{inspect(reason)}), falling back to Chat.Brain"
          )

          brain_fallback(state, text)
      end

    assistant_msg = %{
      "role" => "assistant",
      "content" => reply,
      "sources" => sources,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    new_messages =
      (state.messages ++ [user_msg, assistant_msg])
      |> Enum.take(-@max_messages)

    new_state = %{state | messages: new_messages}
    persist!(new_state)

    {:reply, {:ok, reply, sources}, new_state}
  end

  @impl true
  def handle_call(:history, _from, state) do
    {:reply, state.messages, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    new_state = %{state | messages: []}
    persist!(new_state)
    {:reply, :ok, new_state}
  end

  # ── Copilot agent path ───────────────────────────────────────────────────

  defp run_copilot(state, text) do
    context_slug = fetch_context_slug(state.context_id)

    meta = %{
      "context_slug" => context_slug,
      "page_slug" => state.page_slug,
      "history" => Enum.take(state.messages, -10)
    }

    {:ok, agent_session} = Copilot.run(text, state.context_id, meta: meta)

    case wait_for_session(agent_session.id, @agent_timeout_ms) do
      {:ok, summary, agent_sources} ->
        sources = normalize_sources(agent_sources, context_slug)
        {:ok, summary, sources}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    reason ->
      Logger.warning(
        "Chat.Server: copilot agent raised #{Exception.format(:error, reason, __STACKTRACE__)}"
      )

      {:error, reason}
  end

  defp wait_for_session(session_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_session(session_id, deadline)
  end

  defp poll_session(session_id, deadline) do
    case Repo.get(AgentSession, session_id) do
      %{status: "done", summary: summary, meta: meta} ->
        # The Engine marks sessions as "done" even when a step fails
        # (it passes the error message as summary). Detect error summaries
        # and treat them as failures so the server falls back to Brain.
        if error_summary?(summary) do
          {:error, {:agent_failed, summary}}
        else
          sources = get_in(meta || %{}, ["sources"]) || []
          {:ok, summary || "Agent completed", sources}
        end

      %{status: "failed", summary: summary} ->
        {:error, {:agent_failed, summary}}

      %{status: "cancelled"} ->
        {:error, :cancelled}

      _other ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, :timeout}
        else
          Process.sleep(@agent_poll_interval_ms)
          poll_session(session_id, deadline)
        end
    end
  end

  # The Engine finishes sessions with status "done" even when a step fails,
  # embedding the error in the summary string. Detect these so we can fall back.
  defp error_summary?(nil), do: false

  defp error_summary?(summary) when is_binary(summary) do
    summary =~ "Agent step failed" or
      summary =~ "Agent reached max steps" or
      summary =~ "Agent step timed out" or
      summary =~ "Agent crashed"
  end

  # ── Brain fallback ───────────────────────────────────────────────────────

  defp brain_fallback(state, text) do
    case Brain.answer(state.context_id, text, state.messages, current_page: state.page_slug) do
      {:ok, reply, sources} -> {reply, sources}
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp fetch_context_slug(context_id) do
    case Repo.get(Dran.Brain.Context, context_id) do
      %{slug: slug} -> slug
      nil -> "personal"
    end
  end

  # Agent sessions store sources as a list of slug strings (from the
  # copilot's `extract_sources`). Normalize them into the map shape the
  # chat API expects: `%{"slug" => slug, "title" => slug}`.
  defp normalize_sources(agent_sources, _context_slug) when is_list(agent_sources) do
    Enum.map(agent_sources, fn
      %{"slug" => _slug, "title" => _title} = source -> source
      slug when is_binary(slug) -> %{"slug" => slug, "title" => slug}
      other -> other
    end)
  end

  defp normalize_sources(_, _), do: []

  # ── Persistence ──────────────────────────────────────────────────────────

  defp load_or_create_session(context_id, user, page_slug) do
    case Repo.get_by(Session, context_id: context_id, user: user) do
      nil ->
        {:ok, session} =
          %Session{}
          |> Session.changeset(%{
            context_id: context_id,
            user: user,
            messages: %{"items" => []},
            page_slug: page_slug
          })
          |> Repo.insert()

        session

      session ->
        session
    end
  end

  defp persist!(%{session: session, messages: messages}) do
    session
    |> Session.changeset(%{messages: %{"items" => messages}})
    |> Repo.update()
  end

  # ── Sandbox support ──────────────────────────────────────────────────────

  defp maybe_allow_sandbox(nil), do: :ok

  defp maybe_allow_sandbox(owner) when is_pid(owner) do
    Ecto.Adapters.SQL.Sandbox.allow(Dran.Repo, owner, self())
  end
end
