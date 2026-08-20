defmodule DranWeb.PageCardComponents do
  use Phoenix.Component
  use Gettext, backend: DranWeb.Gettext
  import DranWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders a single page card with type badge, title, excerpt, and meta.
  Used in list views (notes, concepts, entities, etc.)
  """
  attr :page, :map,
    required: true,
    doc: "%Page{} struct or map with title, slug, page_type, meta, inserted_at"

  attr :meta_badges, :list, default: [], doc: "extra badges to show (e.g. community_id, pagerank)"
  attr :class, :string, default: ""
  attr :navigate, :string, default: nil, doc: "path to navigate on click"

  def page_card(assigns) do
    ~H"""
    <div
      :if={@navigate}
      class={[
        "surface-2 rounded-xl p-4 transition-all duration-150 hover:shadow-md hover:scale-[1.01] cursor-pointer group",
        @class
      ]}
      phx-click={Phoenix.LiveView.JS.navigate(@navigate)}
    >
      <div class="flex items-center gap-2 mb-2">
        <span
          class="inline-flex items-center gap-1 text-xs font-medium px-2 py-0.5 rounded-full"
          style={"background: #{type_color(@page.page_type)}20; color: #{type_color(@page.page_type)}"}
        >
          <.icon name={type_icon(@page.page_type)} class="size-3" />
          {@page.page_type}
        </span>
        <span :if={Map.get(@page, :meta, %{})["kind"]} class="text-xs text-base-content/50">
          / {Map.get(@page.meta, "kind")}
        </span>
      </div>
      <h3 class="font-semibold text-sm mb-1 group-hover:text-primary transition-colors line-clamp-1">
        {@page.title}
      </h3>
      <p
        :if={Map.get(@page, :meta, %{})["summary"]}
        class="text-xs text-base-content/60 line-clamp-2 mb-2"
      >
        {Map.get(@page.meta, "summary")}
      </p>
      <div class="flex items-center gap-2 flex-wrap">
        <span
          :for={tag <- (Map.get(@page, :meta, %{})["tags"] || []) |> Enum.take(3)}
          class="text-[10px] px-1.5 py-0.5 rounded bg-base-300/50 text-base-content/50"
        >
          {tag}
        </span>
        <span :if={Map.get(@page.meta, "pagerank")} class="text-[10px] text-primary/60 ml-auto">
          ⭐ {Float.round(Map.get(@page.meta, "pagerank", 0) * 1, 2)}
        </span>
        <span :if={Map.get(@page.meta, "community_id")} class="text-[10px] text-accent/60">
          🏘️ #{Map.get(@page.meta, "community_id")}
        </span>
      </div>
    </div>
    """
  end

  @doc "Renders a grid of page cards."
  attr :pages, :list, required: true
  attr :class, :string, default: ""

  def page_card_grid(assigns) do
    ~H"""
    <div class={"grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4 #{@class}"}>
      <.page_card :for={page <- @pages} page={page} navigate={page_url(page)} />
    </div>
    """
  end

  @doc "Renders a list of page cards (vertical)."
  attr :pages, :list, required: true
  attr :class, :string, default: ""

  def page_card_list(assigns) do
    ~H"""
    <div class={"space-y-3 #{@class}"}>
      <.page_card :for={page <- @pages} page={page} navigate={page_url(page)} />
    </div>
    """
  end

  # Private helpers
  defp type_color("note"), do: "#60A5FA"
  defp type_color("concept"), do: "#FBBF24"
  defp type_color("entity"), do: "#FB7185"
  defp type_color("reference"), do: "#60A5FA"
  defp type_color("project"), do: "#22D3EE"
  defp type_color("goal"), do: "#F59E0B"
  defp type_color("plan"), do: "#A78BFA"
  defp type_color("todo"), do: "#34D399"
  defp type_color(_), do: "#94A3B8"

  defp type_icon("note"), do: "hero-document-text"
  defp type_icon("concept"), do: "hero-light-bulb"
  defp type_icon("entity"), do: "hero-user-group"
  defp type_icon("reference"), do: "hero-bookmark"
  defp type_icon("project"), do: "hero-rocket-launch"
  defp type_icon("goal"), do: "hero-flag"
  defp type_icon("plan"), do: "hero-clipboard-document-list"
  defp type_icon("todo"), do: "hero-check-circle"
  defp type_icon(_), do: "hero-document"

  defp page_url(%{page_type: "note", slug: s}), do: "/notes/#{s}"
  defp page_url(%{page_type: "concept", slug: s}), do: "/panel/concepts/#{s}"
  defp page_url(%{page_type: "entity", slug: s}), do: "/panel/entities/#{s}"
  defp page_url(%{page_type: "reference", slug: s}), do: "/panel/references/#{s}"
  defp page_url(_), do: "#"
end
