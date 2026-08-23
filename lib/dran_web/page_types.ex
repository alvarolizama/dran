defmodule DranWeb.PageTypes do
  @moduledoc """
  Centralized page type UI mappings — delegates to `Dran.PageRegistry`.

  Only presentation lives here (path, label, icon, plural). What a type
  CAN do (graph, journey, embeddings, MCP-create) is defined in
  `Dran.PageTypes`, which also delegates to `Dran.PageRegistry`.

  All data has been consolidated into `Dran.PageRegistry` — the single
  source of truth. This module keeps the public API that templates call
  (`path/1`, `label/1`, `icon/1`, `plural/1`, `page_show_path/2`, etc.)
  so existing HEEx templates work unchanged.
  """

  @doc "Returns the full types map (path/label/icon/plural per type)."
  def all, do: Dran.PageRegistry.all()

  @doc "Returns the list of valid page type keys."
  defdelegate keys, to: Dran.PageRegistry, as: :types

  @doc "Resolves a URL path segment back to a page type (e.g. \"notes\" → \"note\")."
  defdelegate type_from_path(path_segment), to: Dran.PageRegistry

  @doc "Returns the URL path segment for a page type (e.g. `\"notes\"`)."
  defdelegate path(type), to: Dran.PageRegistry

  @doc "Returns the singular display label for a page type, localized (e.g. `\"Nota\"`)."
  defdelegate label(type), to: Dran.PageRegistry

  @doc "Returns the icon name for a page type."
  defdelegate icon(type), to: Dran.PageRegistry

  @doc "Returns the plural display label for a page type, localized (e.g. `\"Notas\"`)."
  defdelegate plural(type), to: Dran.PageRegistry

  @doc """
  Returns the show path for a page struct or map.

  Pages live under the workspace scope: `/:workspace_slug/:type_path/:slug`.
  Falls back to `/:type_path/:slug` when no workspace slug is available.

  ## Examples

      iex> DranWeb.PageTypes.page_show_path(%Page{page_type: "note", slug: "my-note"}, "personal")
      "/personal/notes/my-note"
  """
  def page_show_path(page, workspace_slug \\ nil)

  def page_show_path(%Dran.Page{page_type: type, slug: slug}, workspace_slug)
      when is_binary(type) and is_binary(slug) do
    build_page_show_path(type, slug, workspace_slug)
  end

  def page_show_path(%{page_type: type, slug: slug}, workspace_slug)
      when is_binary(type) and is_binary(slug) do
    build_page_show_path(type, slug, workspace_slug)
  end

  def page_show_path(_, _), do: "#"

  defp build_page_show_path(type, slug, nil), do: "/#{Dran.PageRegistry.path(type)}/#{slug}"

  defp build_page_show_path(type, slug, workspace_slug),
    do: "/#{workspace_slug}/#{Dran.PageRegistry.path(type)}/#{slug}"
end
