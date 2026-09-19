defmodule DranWeb.MemoryLive do
  @moduledoc """
  LiveView for the workspace's shared multi-agent memory.

  Shows every stored fact with full attribution (who stored it via
  `created_by`, when via `inserted_at`, and from which session), its trust
  score, and live updates: the view subscribes to the dedicated
  "memory:<workspace_id>" PubSub topic, so facts stored by workers through
  the REST API appear without a reload (`Dran.Memory` broadcasts
  `{:memory_changed, ...}`).

  The search box runs the trust-weighted hybrid search (`Dran.Memory.search/3`)
  with `bump_retrieval: false` — typing in the UI must not inflate the
  retrieval counters that the workers' API path uses as a usage signal.
  Search always covers active memories, regardless of the status filter
  (superseded facts are excluded from search by design).
  """

  use DranWeb, :live_view

  alias Dran.Memory
  alias Dran.Actors
  alias DranWeb.Plugs.Auth

  @page_size 30

  @impl true
  def mount(params, session, socket) do
    # The URL slug wins over the session (see Plugs.Auth.assign_to_socket/3).
    {socket, context} = Auth.assign_to_socket(socket, session, params)

    if context do
      Phoenix.PubSub.subscribe(Dran.PubSub, "memory:#{context.id}")
    end

    socket =
      assign(socket,
        context: context,
        active_nav: "memory",
        page_title: gettext("Memory"),
        query: "",
        status_filter: "active",
        page: 0,
        memories: [],
        creator_labels: %{},
        memory_count: safe_count(context, nil),
        has_more: false,
        # Toggle "todo el workspace | solo míos": solo se ofrece cuando el
        # workspace COMPARTE memoria (en aislado la política ya filtra y el
        # toggle no tendría efecto). Se evalúa con el `context` local: dentro
        # del assign/2 el socket todavía no lleva el assign nuevo.
        content_scope: content_scope_assign(socket, context),
        show_scope_toggle: show_scope_toggle?(context)
      )

    {:ok, reload_memories(socket)}
  end

  @impl true
  def handle_event("set_content_scope", %{"scope" => scope}, socket)
      when scope in ~w(all own) do
    context = socket.assigns.context
    user = socket.assigns[:user]

    persisted =
      case user do
        %Dran.Accounts.User{} ->
          Dran.Accounts.update_content_scope(user, context, scope)

        _ ->
          # Sin usuario con membresía no hay preferencia que persistir: el
          # cambio aplica solo a esta sesión.
          {:ok, :session_only}
      end

    case persisted do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(content_scope: scope)
         |> put_flash(:info, scope_label(scope))
         |> reload_memories()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save the preference"))}
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(query: q, page: 0) |> reload_memories()}
  end

  def handle_event("filter_status", %{"status" => status}, socket)
      when status in ~w(active superseded all) do
    {:noreply, socket |> assign(status_filter: status, page: 0) |> reload_memories()}
  end

  def handle_event("load_more", _params, socket) do
    {:noreply, fetch_more(socket)}
  end

  def handle_event("feedback", %{"id" => id, "helpful" => helpful}, socket) do
    helpful? = helpful == "true"
    context = socket.assigns.context

    # Row-level authorization first: a forged phx event carries arbitrary
    # ids, and record_feedback/2 has no workspace filter — scope like delete.
    with %Memory{} <- Memory.get_scoped_memory(id, context.id),
         {:ok, updated} <- Memory.record_feedback(id, helpful?) do
      {:noreply, replace_memory(socket, updated)}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Memory not found"))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    context = socket.assigns.context

    with %Memory{} = memory <- Memory.get_scoped_memory(id, context.id),
         {:ok, _} <- Memory.delete_memory(memory) do
      # The broadcast fires handle_info, but reload here too so the UI
      # updates deterministically within the same event.
      {:noreply, reload_memories(socket)}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Memory not found"))}
    end
  end

  def handle_event("purge", %{"id" => id}, socket) do
    context = socket.assigns.context

    with %Memory{} = memory <- Memory.get_scoped_memory(id, context.id),
         {:ok, _} <- Memory.purge_memory(memory) do
      {:noreply, reload_memories(socket)}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Memory not found"))}
    end
  end

  def handle_event("purge_superseded", _params, socket) do
    context = socket.assigns.context

    case Memory.purge_superseded(context.id) do
      {0, _} ->
        {:noreply, put_flash(socket, :info, gettext("No stale memories to delete"))}

      {count, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{count} memories permanently deleted", count: count))
         |> reload_memories()}
    end
  end

  @impl true
  def handle_info({:memory_changed, _action, _memory}, socket) do
    # A fact was created/deleted (by a worker via the REST API, or by this
    # view) — reload from the DB and refresh the sidebar badge count.
    {:noreply,
     socket
     |> assign(memory_count: safe_count(socket.assigns.context, memory_scope(socket)))
     |> reload_memories()}
  end

  # Defensive catch-all: unknown messages on the memory topic are ignored.
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      user={@user}
      workspace_slug={@workspace_slug}
      workspaces={@workspaces}
      active_nav={@active_nav}
    >
      <div class="flex-1 overflow-y-auto">
        <div class="w-full p-6 space-y-6">
          <.memory_header count={@memory_count} workspace={@workspace} />

          <div class="flex flex-col gap-3 sm:flex-row sm:items-center">
            <form id="memory-search-form" phx-change="search" class="relative flex-1">
              <.icon
                name="hero-magnifying-glass"
                class="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-base-content/40 pointer-events-none"
              />
              <input
                id="memory-search-input"
                type="text"
                name="q"
                value={@query}
                phx-debounce="300"
                placeholder={gettext("Search worker memory...")}
                class="w-full py-2 pl-9 pr-3 text-sm rounded-lg border border-base-300 bg-base-100 transition-colors duration-150 focus:outline-none focus:ring-1 focus:ring-primary"
              />
            </form>

            <div
              role="group"
              aria-label={gettext("Filter by status")}
              class="inline-flex rounded-lg bg-base-200 p-1 self-start"
            >
              <.status_filter_button
                id="memory-filter-active"
                value="active"
                label={gettext("Active")}
                active={@status_filter == "active"}
              />
              <.status_filter_button
                id="memory-filter-superseded"
                value="superseded"
                label={gettext("Stale")}
                active={@status_filter == "superseded"}
              />
              <.status_filter_button
                id="memory-filter-all"
                value="all"
                label={gettext("All")}
                active={@status_filter == "all"}
              />
            </div>

            <div
              :if={@show_scope_toggle}
              id="memory-scope-toggle"
              role="group"
              aria-label={gettext("Memory scope")}
              class="inline-flex rounded-lg bg-base-200 p-1 self-start"
            >
              <.scope_button
                id="memory-scope-all"
                value="all"
                label={gettext("All")}
                icon="hero-users"
                active={@content_scope == "all"}
              />
              <.scope_button
                id="memory-scope-own"
                value="own"
                label={gettext("Only mine")}
                icon="hero-user"
                active={@content_scope == "own"}
              />
            </div>

            <button
              :if={@status_filter in ["superseded", "all"] and @query == ""}
              id="memory-purge-superseded"
              phx-click="purge_superseded"
              data-confirm={gettext("Permanently delete ALL stale memories?")}
              class="inline-flex items-center gap-1 rounded-lg border border-base-300 bg-base-100 px-3 py-1.5 text-xs font-medium text-base-content/70 shadow-sm transition-colors duration-150 hover:bg-error/10 hover:text-error"
              title={gettext("Permanent deletion — cannot be undone")}
            >
              <.icon name="hero-trash" class="size-3.5" />
              {gettext("Delete stale")}
            </button>
          </div>

          <.search_notice :if={@query != ""} query={@query} count={length(@memories)} />

          <div id="memory-list" class="space-y-3">
            <.memory_card
              :for={entry <- @memories}
              id={"memory-#{entry.memory.id}"}
              memory={entry.memory}
              score={entry.score}
              related={Map.get(entry, :related, [])}
              labels={@creator_labels}
            />

            <.empty_state
              :if={@memories == []}
              icon="hero-cpu-chip"
              title={gettext("No memories")}
              caption={
                gettext("Workers store facts here through the /api/memory API; they appear live.")
              }
              class="surface-2 rounded-2xl"
            />
          </div>

          <div :if={@has_more and @query == ""} class="flex justify-center">
            <button id="memory-load-more" phx-click="load_more" class="btn btn-ghost btn-sm">
              {gettext("Load more")}
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Data loading ───────────────────────────────────────────────────────────

  # Reset reload (mount, search, filter, broadcast): first page only.
  # "load_more" appends via fetch_more/1 — offset+limit, so each click costs
  # one @page_size query instead of re-reading every loaded row from zero.
  defp reload_memories(socket) do
    context = socket.assigns.context
    scope = memory_scope(socket)

    entries =
      if context do
        cond do
          blank?(socket.assigns.query) ->
            fetch_page(context, socket.assigns.status_filter, 0, scope)

          true ->
            results =
              Memory.search(context.id, socket.assigns.query,
                limit: 20,
                bump_retrieval: false,
                scope: scope
              )

            %{memories: results, has_more: false}
        end
      else
        %{memories: [], has_more: false}
      end

    # Related-fact neighbours (semantic memory↔memory edges derived by the
    # MemoryLinker), batched in ONE query for the whole page — per-card
    # lookups would be N+1 on a list that grows live.
    entries = attach_related(entries, context, socket)

    assign(socket,
      memories: entries.memories,
      has_more: entries.has_more,
      page: 0,
      creator_labels: creator_labels_for(entries.memories)
    )
  end

  # Nombre para pintar la autoría de cada hecho: UNA query para toda la página,
  # no una por tarjeta (ver Dran.Actors.creator_labels/1). Lo guardado sigue
  # siendo el identificador; esto es solo lo que se muestra.
  defp creator_labels_for(entries) do
    Actors.creator_labels(Enum.map(entries, & &1.memory.created_by))
  end

  # Attach each memory's related-fact snippets to the entries map. Only
  # active memories carry semantic edges (the nightly sweep drops the rest).
  defp attach_related(entries, nil, _socket), do: entries

  defp attach_related(entries, context, socket) do
    ids = Enum.map(entries.memories, & &1.memory.id)

    related_by_id =
      if ids == [] do
        %{}
      else
        # El vecino pasa por el mismo filtro de visibilidad: un fact oculto
        # no se asoma por la fila de "related".
        Memory.related_snapshots(context.id, ids, scope: memory_scope(socket))
      end

    Map.update!(entries, :memories, fn memories ->
      Enum.map(memories, fn entry ->
        Map.put(entry, :related, Map.get(related_by_id, entry.memory.id, []))
      end)
    end)
  end

  defp fetch_more(socket) do
    context = socket.assigns.context
    next_page = socket.assigns.page + 1

    entries = fetch_page(context, socket.assigns.status_filter, next_page, memory_scope(socket))

    assign(socket,
      memories: socket.assigns.memories ++ entries.memories,
      has_more: entries.has_more,
      page: next_page,
      creator_labels:
        Map.merge(socket.assigns.creator_labels, creator_labels_for(entries.memories))
    )
  end

  # Fetch one extra row to detect has_more without a count query.
  defp fetch_page(nil, _status_filter, _page, _scope), do: %{memories: [], has_more: false}

  defp fetch_page(context, status_filter, page, scope) do
    memories =
      Memory.list_memories(context.id,
        status: status_opt(status_filter),
        limit: @page_size + 1,
        offset: page * @page_size,
        scope: scope
      )

    has_more = length(memories) > @page_size

    %{
      memories: memories |> Enum.take(@page_size) |> Enum.map(&%{memory: &1, score: nil}),
      has_more: has_more
    }
  end

  defp status_opt("all"), do: nil
  defp status_opt(status), do: status

  defp replace_memory(socket, %Memory{} = updated) do
    entries =
      Enum.map(socket.assigns.memories, fn
        %{memory: %Memory{id: id}} when id == updated.id -> %{memory: updated, score: nil}
        entry -> entry
      end)

    assign(socket, memories: entries)
  end

  defp safe_count(nil, _scope), do: 0

  defp safe_count(%{id: workspace_id}, scope) do
    Memory.count_memories(workspace_id, scope: scope)
  rescue
    _ -> 0
  end

  # El scope de lectura sale del módulo único de política, resuelto con la
  # identidad del socket (el struct User) y la política del workspace.
  defp memory_scope(socket) do
    Dran.ContentVisibility.resolve(
      socket.assigns[:context],
      socket.assigns[:user],
      :memory
    )
  end

  # El toggle se lee de la preferencia persistida del usuario (no de un
  # assign efímero), así sobrevive a un reload de la vista.
  defp content_scope_assign(socket, context) do
    case {socket.assigns[:user], context} do
      {%Dran.Accounts.User{id: user_id}, %{id: workspace_id}} ->
        Dran.ContentVisibility.content_scope_for(user_id, workspace_id)

      _ ->
        "all"
    end
  end

  # "Only mine" no se ofrece cuando el workspace ya está aislado: la política
  # fuerza ese scope para todos, así que un toggle sería mentira.
  defp show_scope_toggle?(context) do
    case context do
      %{share_memory: shared} -> shared == true
      _ -> false
    end
  end

  defp scope_label("own"), do: gettext("Showing only your memories")
  defp scope_label(_), do: gettext("Showing the whole workspace")

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # ── Render-only components ─────────────────────────────────────────────────

  attr :count, :integer, required: true
  attr :workspace, :any, default: nil

  defp memory_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-3">
      <div>
        <h1 class="text-title">{gettext("Memory")}</h1>
        <p class="text-caption mt-1">
          {gettext("Atomic facts shared by %{name}'s workers.",
            name: workspace_name(@workspace)
          )}
        </p>
      </div>
      <div class="flex items-center gap-1.5 text-caption">
        <span class="size-2 rounded-full bg-success animate-pulse"></span>
        {gettext("Live")}
        <span class="ml-2 px-2 py-0.5 rounded-md bg-base-200 text-xs">
          {@count} {gettext("active")}
        </span>
      </div>
    </div>
    """
  end

  defp workspace_name(nil), do: gettext("this workspace")

  defp workspace_name(%{name: name}) when is_binary(name), do: name
  defp workspace_name(_), do: gettext("this workspace")

  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp status_filter_button(assigns) do
    ~H"""
    <button
      id={@id}
      phx-click="filter_status"
      phx-value-status={@value}
      class={[
        "px-3 py-1 text-xs rounded-md transition-all duration-150",
        @active && "bg-base-100 shadow-sm font-medium",
        !@active && "text-base-content/60 hover:text-base-content"
      ]}
    >
      {@label}
    </button>
    """
  end

  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, required: true

  # Toggle de alcance de lectura ("todo | solo míos"). El mismo lenguaje
  # visual que status_filter_button, con icono para que el alcance se lea de
  # un vistazo.
  defp scope_button(assigns) do
    ~H"""
    <button
      id={@id}
      phx-click="set_content_scope"
      phx-value-scope={@value}
      aria-pressed={to_string(@active)}
      class={[
        "inline-flex items-center gap-1.5 px-3 py-1 text-xs rounded-md transition-all duration-150",
        @active && "bg-base-100 shadow-sm font-medium",
        !@active && "text-base-content/60 hover:text-base-content"
      ]}
    >
      <.icon name={@icon} class="size-3.5" />
      {@label}
    </button>
    """
  end

  attr :query, :string, required: true
  attr :count, :integer, required: true

  defp search_notice(assigns) do
    ~H"""
    <p class="text-caption text-base-content/60">
      {gettext("%{count} results for “%{query}” — search covers active facts.",
        count: @count,
        query: @query
      )}
    </p>
    """
  end

  attr :id, :string, required: true
  attr :memory, :map, required: true
  attr :score, :float, default: nil
  attr :related, :list, default: []
  attr :labels, :map, default: %{}

  defp memory_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "surface-2 rounded-2xl p-4 transition-opacity duration-150",
        @memory.status != "active" && "opacity-60"
      ]}
    >
      <p class="text-sm leading-relaxed">{@memory.content}</p>

      <div
        :if={@related != []}
        class="mt-3 flex flex-wrap items-center gap-1.5 text-xs text-base-content/60"
      >
        <span
          class="inline-flex items-center gap-1 shrink-0"
          title={gettext("Related facts derived automatically (semantic)")}
        >
          <.icon name="hero-arrows-right-left" class="size-3.5" />
          {gettext("Related:")}
        </span>
        <span
          :for={rel <- @related}
          id={"memory-related-#{@memory.id}-#{rel.id}"}
          class="px-1.5 py-0.5 rounded-md bg-base-200/70 max-w-72 truncate"
          title={rel.content}
        >
          {rel.content}
        </span>
      </div>

      <div class="mt-3 flex flex-wrap items-center gap-x-3 gap-y-1.5 text-xs text-base-content/60">
        <span class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-md bg-base-200">
          <.icon name="hero-cpu-chip" class="size-3.5" />
          {Actors.creator_label(@labels, @memory.created_by)}
        </span>

        <span title={absolute_timestamp(@memory.inserted_at)}>{relative_time(@memory.inserted_at)}</span>

        <span
          :if={@memory.source_session}
          class="font-mono text-[10px] truncate max-w-40"
          title={@memory.source_session}
        >
          {@memory.source_session}
        </span>

        <span class="inline-flex items-center gap-1.5" title={gettext("Trust score")}>
          <span class="h-1.5 w-16 rounded-full bg-base-300 overflow-hidden">
            <span
              class="block h-full rounded-full bg-primary"
              style={"width: #{trust_pct(@memory.trust_score)}%"}
            ></span>
          </span>
          {Float.round(@memory.trust_score * 1.0, 2)}
        </span>

        <span :if={@memory.helpful_count > 0} title={gettext("Helpful feedback received")}>
          <.icon name="hero-hand-thumb-up" class="size-3.5 inline" /> {@memory.helpful_count}
        </span>

        <span :if={@score} class="px-1.5 py-0.5 rounded-md bg-primary/10 text-primary">
          {gettext("score")} {Float.round(@score * 1.0, 3)}
        </span>

        <span
          :if={@memory.status != "active"}
          class="px-1.5 py-0.5 rounded-md bg-base-300 text-base-content/60"
        >
          {@memory.status}
        </span>

        <span class="ml-auto flex items-center gap-1">
          <button
            id={"memory-helpful-#{@memory.id}"}
            phx-click="feedback"
            phx-value-id={@memory.id}
            phx-value-helpful="true"
            class="btn btn-ghost btn-xs"
            title={gettext("Helpful (+0.05 trust)")}
          >
            <.icon name="hero-hand-thumb-up" class="size-3.5" />
          </button>
          <button
            id={"memory-unhelpful-#{@memory.id}"}
            phx-click="feedback"
            phx-value-id={@memory.id}
            phx-value-helpful="false"
            class="btn btn-ghost btn-xs"
            title={gettext("Not helpful (−0.10 trust)")}
          >
            <.icon name="hero-hand-thumb-down" class="size-3.5" />
          </button>
          <button
            id={"memory-delete-#{@memory.id}"}
            phx-click="delete"
            phx-value-id={@memory.id}
            class="btn btn-ghost btn-xs text-base-content/50 hover:text-error"
            title={gettext("Mark as stale")}
          >
            <.icon name="hero-trash" class="size-3.5" />
          </button>
          <button
            :if={@memory.status != "active"}
            id={"memory-purge-#{@memory.id}"}
            phx-click="purge"
            phx-value-id={@memory.id}
            data-confirm={gettext("Permanently delete this memory? This cannot be undone.")}
            class="btn btn-ghost btn-xs text-base-content/40 hover:text-error"
            title={gettext("Delete permanently")}
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </span>
      </div>
    </div>
    """
  end

  defp trust_pct(trust) when is_number(trust), do: round(max(0.0, min(1.0, trust)) * 100)
  defp trust_pct(_), do: 0

  # Absolute ISO-8601 timestamp for the relative-time tooltip.
  defp absolute_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp absolute_timestamp(%NaiveDateTime{} = ndt) do
    {:ok, dt} = DateTime.from_naive(ndt, "Etc/UTC")
    DateTime.to_iso8601(dt)
  end

  defp absolute_timestamp(_), do: ""

  defp relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)
    relative_time_from_seconds(diff)
  end

  defp relative_time(%NaiveDateTime{} = ndt) do
    {:ok, dt} = DateTime.from_naive(ndt, "Etc/UTC")
    relative_time(dt)
  end

  defp relative_time(_), do: ""

  defp relative_time_from_seconds(sec) when sec < 60, do: gettext("just now")

  defp relative_time_from_seconds(sec) when sec < 3600,
    do: gettext("%{n}m ago", n: div(sec, 60))

  defp relative_time_from_seconds(sec) when sec < 86_400,
    do: gettext("%{n}h ago", n: div(sec, 3600))

  defp relative_time_from_seconds(sec) when sec < 604_800,
    do: gettext("%{n}d ago", n: div(sec, 86_400))

  defp relative_time_from_seconds(sec) when sec < 2_592_000,
    do: gettext("%{n}w ago", n: div(sec, 604_800))

  defp relative_time_from_seconds(sec),
    do: gettext("%{n}mo ago", n: div(sec, 2_592_000))
end
