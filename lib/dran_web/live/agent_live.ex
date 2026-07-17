defmodule DranWeb.AgentLive do
  @moduledoc """
  Unified LiveView for running Dran agents (research, ingest).
  """

  use DranWeb, :live_view

  alias Dran.{Agent, Repo}
  alias Dran.Agent.{Session, Step}
  alias DranWeb.Plugs.Auth

  import Ecto.Query

  @valid_types ~w(research ingest)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      context_slug={@context_slug}
      contexts={@contexts}
      active_nav={@active_nav}
    >
      <div class="flex-1 overflow-y-auto w-full">
        <div class="w-full p-6 space-y-6">
          <div>
            <h1 class="text-2xl font-bold capitalize">{@type} Agent</h1>
            <p class="text-sm text-base-content/50 mt-1">{@description}</p>
          </div>

          <%= if @session do %>
            <.session_header session={@session} />

            <%= if @session.status == "running" do %>
              <.working_indicator session={@session} steps={@steps} />
            <% end %>

            <.steps_timeline steps={@steps} />

            <%= if @session.status == "done" do %>
              <div class="alert alert-success">
                <.icon name="hero-check-circle" class="size-5" />
                <div>
                  <p class="font-medium">Done</p>
                  <p class="text-sm">{@session.summary}</p>
                </div>
              </div>
            <% end %>
          <% else %>
            <.form
              for={@form}
              id="agent-form"
              phx-submit="start"
              class="space-y-4"
            >
              <.input
                field={@form[:input]}
                type="text"
                label={@input_label}
                placeholder={@input_placeholder}
                class="w-full"
                autofocus
              />
              <div class="flex items-end gap-3">
                <%= if @type == "research" do %>
                  <div class="flex-1">
                    <span class="label mb-1 block text-sm font-medium text-base-content/70">
                      Output language
                    </span>
                    <select
                      name="agent[lang]"
                      class="w-full px-3 py-2 text-sm rounded-lg border border-base-300 bg-base-100 focus:outline-none focus:ring-1 focus:ring-primary"
                    >
                      <option value="es" selected>Español</option>
                      <option value="en">English</option>
                      <option value="fr">Français</option>
                      <option value="de">Deutsch</option>
                      <option value="pt">Português</option>
                      <option value="it">Italiano</option>
                      <option value="ja">日本語</option>
                      <option value="zh">中文</option>
                    </select>
                  </div>
                <% end %>
                <button type="submit" class="btn btn-primary btn-sm shrink-0">
                  <.icon name="hero-play" class="size-4" /> Start
                </button>
              </div>
            </.form>

            <.recent_sessions sessions={@recent_sessions} type={@type} />
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp session_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between p-4 rounded-lg border border-base-300 bg-base-200/30">
      <div class="flex-1 min-w-0">
        <div class="text-sm text-base-content/60">Input</div>
        <div class="font-medium truncate">{@session.input}</div>
        <div class="text-xs text-base-content/40 mt-0.5">
          Language: {session_lang_name(@session)}
        </div>
      </div>
      <div class="flex items-center gap-3">
        <div class="text-right">
          <div class="text-sm text-base-content/60">Status</div>
          <span class={status_badge_class(@session.status)}>{@session.status}</span>
        </div>
        <button
          :if={@session.status == "running"}
          type="button"
          phx-click="stop"
          data-confirm="Stop this agent session?"
          class="btn btn-error btn-sm"
        >
          <.icon name="hero-stop" class="size-4" /> Stop
        </button>
      </div>
    </div>
    """
  end

  defp working_indicator(assigns) do
    ~H"""
    <div
      id={"working-#{@session.id}"}
      class="rounded-lg border border-primary/30 bg-primary/5 p-4 flex items-center gap-4"
    >
      <span class="relative flex size-3 shrink-0">
        <span class="absolute inline-flex h-full w-full rounded-full bg-primary opacity-75 motion-safe:animate-ping"></span>
        <span class="relative inline-flex size-3 rounded-full bg-primary"></span>
      </span>
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <span class="text-sm font-medium text-primary">
            {current_action_label(@steps)}
          </span>
        </div>
        <div class="mt-1.5 h-1 w-full rounded-full bg-base-300 overflow-hidden">
          <div
            class="h-full rounded-full bg-primary motion-safe:transition-all duration-500"
            style={"width: #{progress_pct(@session, @steps)}%"}
          >
          </div>
        </div>
        <div class="mt-1 text-xs text-base-content/50">
          Step {num_steps(@steps)}
          <%= if @session.steps_count > 0 do %>
            of up to {@session.steps_count}
          <% end %>
          · {count_by_status(@steps, "ok")} completed, {count_by_status(@steps, "error")} failed
        </div>
      </div>
      <span class="loading loading-dots loading-sm text-primary shrink-0"></span>
    </div>
    """
  end

  defp current_action_label([]), do: "Starting agent…"

  defp current_action_label(steps) do
    case List.last(steps) do
      %{tool_name: tool, tool_args: args, tool_result: %{"status" => "pending"}} ->
        "Running #{humanize_tool(tool, args)}…"

      %{tool_name: tool, tool_args: args} ->
        "Preparing next step after #{humanize_tool(tool, args)}…"

      _ ->
        "Working…"
    end
  end

  defp humanize_tool("web_search", args) do
    query = args["query"] || ""
    if query != "", do: "web search for \"#{truncate(query, 50)}\"", else: "web search"
  end

  defp humanize_tool("web_scrape", args) do
    url = args["url"] || ""
    if url != "", do: "scraping #{truncate(url, 60)}", else: "page scrape"
  end

  defp humanize_tool("search_pages", args) do
    query = args["query"] || ""
    if query != "", do: "brain search for \"#{truncate(query, 50)}\"", else: "brain search"
  end

  defp humanize_tool("create_page", args) do
    title = args["title"] || ""
    if title != "", do: "creating page \"#{truncate(title, 50)}\"", else: "page creation"
  end

  defp humanize_tool("done", _args), do: "finishing up"

  defp humanize_tool(other, _args), do: other

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "…"
    else
      text
    end
  end

  defp truncate(text, _max), do: text

  defp num_steps(steps), do: length(steps)

  defp count_by_status(steps, status) do
    Enum.count(steps, fn s -> Map.get(s.tool_result || %{}, "status") == status end)
  end

  defp progress_pct(_session, []), do: 3

  defp progress_pct(session, steps) do
    max_steps = max(session.steps_count, length(steps))
    if max_steps > 0, do: min(length(steps) * 100 / max(max_steps, 1), 100), else: 3
  end

  defp status_badge_class("done"), do: "badge badge-success"
  defp status_badge_class("running"), do: "badge badge-primary"
  defp status_badge_class("error"), do: "badge badge-error"
  defp status_badge_class("cancelled"), do: "badge badge-warning"
  defp status_badge_class(_), do: "badge"

  defp recent_sessions(assigns) do
    ~H"""
    <div :if={@sessions != []} class="space-y-3">
      <h2 class="text-sm font-semibold text-base-content/60">Recent sessions</h2>

      <div class="space-y-2">
        <div
          :for={session <- @sessions}
          id={"session-#{session.id}"}
          class="agent-step flex items-center justify-between p-3 rounded-lg border border-base-300 hover:bg-base-200/50 transition"
        >
          <div class="min-w-0">
            <div class="font-medium text-sm truncate">{session.input}</div>
            <div class="text-xs text-base-content/50">
              {format_session_date(session.inserted_at)} · {session.steps_count} steps · {session.pages_created} pages<%= if session_lang(session) != "es" do %>
                · {session_lang(session)}
              <% end %>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <span class={status_badge_class(session.status)}>{session.status}</span>
            <.link
              navigate={~p"/agents/#{@type}/#{session.id}"}
              class="btn btn-ghost btn-xs"
            >
              Resume
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp recent_sessions(socket, type) do
    context = socket.assigns.context

    if context do
      Repo.all(
        from s in Session,
          where: s.context_id == ^context.id and s.agent_type == ^type,
          order_by: [desc: s.inserted_at],
          limit: 10
      )
    else
      []
    end
  end

  defp format_session_date(%DateTime{} = dt) do
    dt
    |> DateTime.to_naive()
    |> NaiveDateTime.to_string()
  end

  defp format_session_date(_), do: ""

  defp session_lang(%{meta: %{"opts" => opts}}) when is_list(opts) do
    Keyword.get(opts, :lang, "es")
  end

  defp session_lang(%{meta: %{"opts" => %{"lang" => lang}}}) when is_binary(lang), do: lang
  defp session_lang(_), do: "es"

  @lang_names %{
    "es" => "Español",
    "en" => "English",
    "fr" => "Français",
    "de" => "Deutsch",
    "pt" => "Português",
    "it" => "Italiano",
    "ja" => "日本語",
    "zh" => "中文"
  }

  defp session_lang_name(session) do
    lang = session_lang(session)
    Map.get(@lang_names, lang, lang)
  end

  defp steps_timeline(assigns) do
    ~H"""
    <div class="space-y-3">
      <h2 class="text-sm font-semibold text-base-content/60">Steps</h2>

      <%= if @steps == [] do %>
        <p class="text-sm text-base-content/50">No steps yet.</p>
      <% else %>
        <div class="space-y-2">
          <div
            :for={step <- @steps}
            id={"step-#{step.id}"}
            class={[
              "agent-step p-3 rounded-lg border transition",
              pending?(step) && "border-primary/40 bg-primary/5",
              not pending?(step) && "border-base-300"
            ]}
          >
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <.icon
                  :if={pending?(step)}
                  name="hero-arrow-path"
                  class="size-4 text-primary motion-safe:animate-spin"
                />
                <span class="font-medium text-sm">{step.step_number}. {step.tool_name}</span>
              </div>
              <span class={result_badge_class(step.tool_result)}>
                {Map.get(step.tool_result || %{}, "status", "pending")}
              </span>
            </div>
            <%= if step.reasoning && step.reasoning != "" do %>
              <p class="text-xs text-base-content/60 mt-1">{step.reasoning}</p>
            <% end %>
            <%= if pending?(step) do %>
              <div class="mt-2 flex items-center gap-2 text-xs text-primary">
                <span class="loading loading-dots loading-xs"></span>
                <span>Executing…</span>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp pending?(%{tool_result: %{}}), do: false
  defp pending?(%{tool_result: nil}), do: true
  defp pending?(_), do: false

  defp result_badge_class(%{"status" => "error"}), do: "badge badge-error badge-sm"
  defp result_badge_class(%{"status" => "done"}), do: "badge badge-success badge-sm"
  defp result_badge_class(%{"status" => "ok"}), do: "badge badge-primary badge-sm"
  defp result_badge_class(_), do: "badge badge-ghost badge-sm"

  @impl true
  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    Phoenix.PubSub.subscribe(Dran.PubSub, "agents:all")

    socket =
      if context do
        allow_upload(socket, :file,
          accept: ~w(application/pdf text/plain),
          max_file_size: 10_000_000,
          auto_upload: false
        )
      else
        socket
      end

    {:ok,
     assign(socket,
       context: context,
       active_nav: "agents",
       session: nil,
       steps: [],
       recent_sessions: [],
       form: to_form(%{"input" => ""}, as: :agent)
     )}
  end

  @impl true
  def handle_params(%{"type" => type} = params, _url, socket) when type in @valid_types do
    socket =
      socket
      |> assign(agent_type_label(type))
      |> assign(recent_sessions: recent_sessions(socket, type))
      |> maybe_load_session(params["id"])

    {:noreply, socket}
  end

  def handle_params(%{"type" => _type}, _url, socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  defp agent_type_label("research") do
    %{
      type: "research",
      active_nav: "research",
      input_label: "Research topic",
      input_placeholder: "Yeshe Walmo",
      description: "Explore a topic on the web and create pages.",
      page_title: "Research Agent"
    }
  end

  defp agent_type_label("ingest") do
    %{
      type: "ingest",
      active_nav: "ingest",
      input_label: "URL to ingest",
      input_placeholder: "https://example.com/article",
      description: "Ingest files or URLs and optionally enrich the resulting page.",
      page_title: "Files Ingest"
    }
  end

  defp maybe_load_session(socket, nil), do: socket

  defp maybe_load_session(socket, id) when is_binary(id) do
    case Repo.get(Session, id) do
      nil ->
        socket

      session ->
        if session.context_id == socket.assigns.context.id do
          steps =
            Repo.all(
              from s in Step, where: s.session_id == ^session.id, order_by: [asc: s.step_number]
            )

          Phoenix.PubSub.subscribe(Dran.PubSub, "agents:#{session.id}")
          assign(socket, session: session, steps: steps)
        else
          socket
        end
    end
  end

  @impl true
  def handle_event("start", %{"agent" => agent_params}, socket) do
    context = socket.assigns.context
    type = socket.assigns.type
    input = agent_params["input"]
    lang = if type == "research", do: agent_params["lang"] || "es", else: nil

    if context && String.trim(input) != "" do
      case start_agent(type, input, context.id, lang: lang) do
        {:ok, session} ->
          Phoenix.PubSub.subscribe(Dran.PubSub, "agents:#{session.id}")

          {:noreply,
           socket
           |> assign(session: session, steps: [], recent_sessions: recent_sessions(socket, type))
           |> push_navigate(to: ~p"/agents/#{type}/#{session.id}")}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to start agent: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Input and context are required")}
    end
  end

  @impl true
  def handle_event("stop", _params, socket) do
    if socket.assigns.session && socket.assigns.session.status == "running" do
      :ok = Dran.Agent.Engine.cancel(socket.assigns.session.id)
      {:noreply, refresh_session(socket) |> put_flash(:info, "Agent stopped")}
    else
      {:noreply, socket}
    end
  end

  defp start_agent("research", input, context_id, opts),
    do: Agent.Research.run(input, context_id, opts)

  defp start_agent("ingest", input, context_id, _opts),
    do: Agent.Ingest.run(input, context_id)

  @impl true
  def handle_info({:agent, session_id, message}, socket) do
    socket =
      if socket.assigns.session && socket.assigns.session.id == session_id do
        handle_agent_message(socket, message)
      else
        socket
      end

    # Refresh recent list if we're on the index page (no session loaded)
    {:noreply,
     if socket.assigns.session do
       socket
     else
       assign(socket, recent_sessions: recent_sessions(socket, socket.assigns.type))
     end}
  end

  def handle_info(message, socket) do
    socket =
      if socket.assigns.session do
        handle_agent_message(socket, message)
      else
        socket
      end

    {:noreply, socket}
  end

  defp handle_agent_message(socket, {:step_started, _step}) do
    refresh_steps(socket)
  end

  defp handle_agent_message(socket, {:step_completed, _step, _result}) do
    refresh_steps(socket)
  end

  defp handle_agent_message(socket, {:session_done, summary, _pages_created}) do
    socket
    |> refresh_session()
    |> put_flash(:info, summary)
  end

  defp handle_agent_message(socket, {:page_created, _page}) do
    socket
  end

  defp handle_agent_message(socket, _message) do
    socket
  end

  defp refresh_session(socket) do
    session = Repo.get(Session, socket.assigns.session.id)
    assign(socket, session: session)
  end

  defp refresh_steps(socket) do
    steps =
      Repo.all(
        from s in Step,
          where: s.session_id == ^socket.assigns.session.id,
          order_by: [asc: s.step_number]
      )

    assign(socket, steps: steps)
  end
end
