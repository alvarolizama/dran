defmodule Dran.Chat.Server do
  @moduledoc """
  GenServer backing a single chat conversation.

  Each conversation is identified by (context_id, user) and persisted to
  `Dran.Chat.Session`. The server keeps the last 20 messages in memory
  and persists the same 20 to the database on every turn.

  ## Lifecycle

  Started via `Dran.Chat.Supervisor.find_or_start/2` (DynamicSupervisor +
  Registry). `restart: :temporary` — if the process dies it is not
  automatically restarted; the next `find_or_start` will reload from DB.

  ## API

  - `send_message(pid, text)` → `{:ok, reply, sources}`
  - `history(pid)` → list of message maps
  - `clear(pid)` → `:ok`
  """

  use GenServer, restart: :temporary

  alias Dran.Chat.{Brain, Session}
  alias Dran.Repo

  @max_messages 20

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

    case Brain.answer(state.context_id, text, state.messages, current_page: state.page_slug) do
      {:ok, reply, sources} ->
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
