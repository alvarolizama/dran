defmodule DranWeb.CommandPalette do
  @moduledoc """
  Global Command Palette (Cmd+K / Ctrl+K) LiveComponent.

  Rendered in the app layout so it is available on every page.
  A JS hook listens for the Cmd/Ctrl+K shortcut, ArrowUp/Down/Enter
  navigation, and Escape to close.
  """

  use DranWeb, :live_component

  alias Dran.Brain
  alias DranWeb.PageTypes

  @quick_actions [
    %{label: "New Note", icon: "hero-plus", path: "/panel/notes/new"},
    %{label: "New Todo", icon: "hero-check-circle", path: "/panel/todos/new"},
    %{label: "New Project", icon: "hero-rocket-launch", path: "/panel/projects/new"},
    %{label: "Go to Kanban", icon: "hero-view-columns", path: "/panel/kanban"},
    %{label: "Go to Graph", icon: "hero-share", path: "/panel/graph"},
    %{label: "Go to Todos", icon: "hero-list-bullet", path: "/panel/todos"},
    %{label: "Go to Dashboard", icon: "hero-home", path: "/"}
  ]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open, false)
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:selected, 0)
     |> assign(:quick_actions, @quick_actions)}
  end

  @impl true
  def update(%{workspace_slug: workspace_slug} = assigns, socket) do
    disabled_types =
      case workspace_slug && Brain.get_workspace_by_slug(workspace_slug) do
        %{disabled_page_types: disabled} when is_list(disabled) -> disabled
        _ -> []
      end

    # Map quick action keys to page types for filtering
    action_page_types = %{
      "New Note" => "note",
      "New Todo" => "todo",
      "New Project" => "project",
      "Go to Kanban" => "todo",
      "Go to Todos" => "todo"
    }

    filtered_actions =
      Enum.reject(@quick_actions, fn action ->
        page_type = Map.get(action_page_types, action.label)
        page_type && page_type in disabled_types
      end)

    {:ok,
     socket
     |> assign(:workspace_slug, workspace_slug)
     |> assign(:id, assigns[:id] || "command-palette")
     |> assign(:quick_actions, filtered_actions)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} phx-hook="CommandPalette" phx-target={@myself}>
      <div
        :if={@open}
        class="fixed inset-0 z-50 bg-black/50 backdrop-blur-sm"
        phx-click="close"
        phx-target={@myself}
      >
        <div
          class="mx-auto max-w-lg w-full rounded-xl border border-base-300 bg-base-100 shadow-2xl"
          style="margin-top: 15vh;"
          role="dialog"
          aria-modal="true"
          aria-label={gettext("Command palette")}
          phx-click-away="close"
          phx-target={@myself}
        >
          <div class="relative">
            <.icon
              name="hero-magnifying-glass"
              class="absolute left-3 top-3.5 size-4 text-base-content/50"
            />
            <input
              type="text"
              name="query"
              value={@query}
              phx-keyup="search"
              phx-debounce="200"
              phx-target={@myself}
              placeholder={gettext("Search pages, actions...")}
              autocomplete="off"
              aria-label={gettext("Search")}
              class="w-full pl-10 pr-4 py-3 text-sm rounded-t-xl bg-transparent border-b border-base-300 focus:outline-none focus:ring-1 focus:ring-primary"
              autofocus
            />
          </div>

          <div :if={@query == ""} class="p-2">
            <ul role="listbox" aria-label={gettext("Quick actions")}>
              <li
                :for={{action, i} <- Enum.with_index(@quick_actions)}
                role="option"
                aria-selected={i == @selected}
                class={[
                  "flex items-center gap-3 px-3 py-2 rounded-lg cursor-pointer text-sm hover:bg-base-200 transition",
                  i == @selected && "bg-primary/10"
                ]}
                phx-click="navigate_action"
                phx-value-index={i}
                phx-target={@myself}
              >
                <.icon name={action.icon} class="size-4 shrink-0 text-base-content/60" />
                <span>{action.label}</span>
              </li>
            </ul>
          </div>

          <div :if={@query != ""} class="p-2 max-h-80 overflow-y-auto">
            <ul :if={length(@results) > 0} role="listbox">
              <li
                :for={{result, i} <- Enum.with_index(@results)}
                role="option"
                aria-selected={i == @selected}
                class={[
                  "flex items-center gap-3 px-3 py-2 rounded-lg cursor-pointer text-sm hover:bg-base-200 transition",
                  i == @selected && "bg-primary/10"
                ]}
                phx-click="navigate"
                phx-value-slug={result.slug}
                phx-value-type={result.page_type}
                phx-target={@myself}
              >
                <.icon
                  name={PageTypes.icon(result.page_type)}
                  class="size-4 shrink-0 text-base-content/60"
                />
                <div class="flex-1 min-w-0">
                  <div class="truncate">{result.title}</div>
                  <div class="text-xs text-base-content/40">{PageTypes.label(result.page_type)}</div>
                </div>
              </li>
            </ul>

            <div
              :if={length(@results) == 0}
              class="flex flex-col items-center gap-2 py-8 text-base-content/40"
            >
              <.icon name="hero-face-frown" class="size-8" />
              <span class="text-sm">{gettext("No results")}</span>
            </div>
          </div>

          <div class="flex items-center gap-4 px-4 py-2 border-t border-base-300 text-[10px] font-mono text-base-content/40">
            <span class="flex items-center gap-1"><kbd class="border rounded px-1">↑↓</kbd> navigate</span>
            <span class="flex items-center gap-1"><kbd class="border rounded px-1">↵</kbd> open</span>
            <span class="flex items-center gap-1"><kbd class="border rounded px-1">esc</kbd> close</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Event handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("toggle", _params, socket) do
    new_open = !socket.assigns.open

    {:noreply,
     socket
     |> assign(:open, new_open)
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:selected, 0)}
  end

  def handle_event("open", _params, socket) do
    {:noreply,
     socket
     |> assign(:open, true)
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:selected, 0)}
  end

  def handle_event("close", _params, socket) do
    {:noreply,
     socket
     |> assign(:open, false)
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:selected, 0)}
  end

  def handle_event("search", %{"query" => query}, socket) do
    results =
      if String.length(String.trim(query)) >= 2 do
        do_search(socket.assigns.workspace_slug, query)
      else
        []
      end

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:results, results)
     |> assign(:selected, 0)}
  end

  def handle_event("key", %{"key" => "ArrowDown"}, socket) do
    max = list_size(socket.assigns)
    {:noreply, assign(socket, :selected, min(socket.assigns.selected + 1, max - 1))}
  end

  def handle_event("key", %{"key" => "ArrowUp"}, socket) do
    {:noreply, assign(socket, :selected, max(socket.assigns.selected - 1, 0))}
  end

  def handle_event("key", %{"key" => "Enter"}, socket) do
    path = resolve_selected_path(socket.assigns)
    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_event("key", _params, socket), do: {:noreply, socket}

  def handle_event("navigate", %{"slug" => slug, "type" => type}, socket) do
    path = "/panel/#{PageTypes.path(type)}/#{slug}"
    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_event("navigate_action", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    action = Enum.at(socket.assigns.quick_actions, index)

    if action do
      {:noreply, push_navigate(socket, to: action.path)}
    else
      {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp list_size(%{query: q, quick_actions: qa}) when q in ["", nil] do
    length(qa)
  end

  defp list_size(%{results: results}) do
    max(length(results), 1)
  end

  defp resolve_selected_path(%{query: q, selected: selected, quick_actions: qa})
       when q in ["", nil] do
    Enum.at(qa, selected, %{path: "/"}).path
  end

  defp resolve_selected_path(%{results: [], selected: _}) do
    "/"
  end

  defp resolve_selected_path(%{results: results, selected: selected}) do
    case Enum.at(results, selected) do
      nil -> "/"
      result -> "/panel/#{PageTypes.path(result.page_type)}/#{result.slug}"
    end
  end

  defp do_search(workspace_slug, query) do
    workspace_id = resolve_workspace_id(workspace_slug)

    try do
      opts = [limit: 8]
      opts = if workspace_id, do: Keyword.put(opts, :workspace_id, workspace_id), else: opts

      case Brain.search(query, opts) do
        {:ok, results} when is_list(results) -> results
        _ -> []
      end
    rescue
      _ -> []
    end
  end

  defp resolve_workspace_id(nil), do: nil

  defp resolve_workspace_id(slug) when is_binary(slug) do
    try do
      case Brain.get_workspace_by_slug(slug) do
        nil -> nil
        context -> context.id
      end
    rescue
      _ -> nil
    end
  end
end
