defmodule DranWeb.GraphHelpers do
  @moduledoc """
  Shared logic for building subgraph data centered on a single page.

  Used by GraphLive (:show) and the inline graph tab on every page detail view.
  """

  alias Dran.Brain

  @type_colors %{
    "note" => "#60A5FA",
    "todo" => "#34D399",
    "goal" => "#F59E0B",
    "plan" => "#A78BFA",
    "entity" => "#FB7185",
    "concept" => "#FBBF24",
    "reference" => "#60A5FA",
    "project" => "#22D3EE",
    "artifact" => "#2DD4BF",
    "query" => "#818CF8"
  }

  @edge_colors %{
    "related" => "#94A3B8",
    "contradicts" => "#EF4444",
    "supersedes" => "#F59E0B",
    "part_of" => "#10B981"
  }

  def type_colors, do: @type_colors
  def edge_colors, do: @edge_colors

  @doc """
  Builds the subgraph centered on `page` with its direct neighbors.

  Returns `%{nodes: [...], edges: [...]}`.
  """
  def build_page_subgraph(page) do
    %{outbound: outbound, inbound: inbound} = Brain.list_relations_for_page(page.id)

    neighbors =
      (Enum.map(outbound, fn r ->
         t = r.target

         %{
           id: t.id,
           slug: t.slug,
           title: t.title,
           type: t.page_type,
           relation_type: r.relation_type
         }
       end) ++
         Enum.map(inbound, fn r ->
           s = r.source

           %{
             id: s.id,
             slug: s.slug,
             title: s.title,
             type: s.page_type,
             relation_type: r.relation_type
           }
         end))
      |> Enum.uniq_by(& &1.id)

    center = %{
      id: page.id,
      slug: page.slug,
      label: page.title,
      type: page.page_type,
      color: Map.get(@type_colors, page.page_type, "#94A3B8"),
      radius: 30,
      x: 400,
      y: 300
    }

    neighbors_laid =
      neighbors
      |> Enum.map(fn n ->
        %{
          id: n.id,
          slug: n.slug,
          label: n.title,
          type: n.type,
          color: Map.get(@type_colors, n.type, "#94A3B8"),
          radius: 20,
          relation_type: n.relation_type
        }
      end)
      |> circular_layout(400, 300, 200)

    edges =
      Enum.map(neighbors_laid, fn n ->
        %{
          source_id: center.id,
          target_id: n.id,
          x1: 400,
          y1: 300,
          x2: n.x,
          y2: n.y,
          color: Map.get(@edge_colors, n.relation_type, "#94A3B8")
        }
      end)

    %{nodes: [center | neighbors_laid], edges: edges}
  end

  def circular_layout(nodes, center_x, center_y, radius) do
    count = length(nodes)

    if count == 0 do
      []
    else
      nodes
      |> Enum.with_index()
      |> Enum.map(fn {node, i} ->
        angle = i / count * 2 * :math.pi()

        node
        |> Map.put(:x, center_x + radius * :math.cos(angle))
        |> Map.put(:y, center_y + radius * :math.sin(angle))
      end)
    end
  end
end
