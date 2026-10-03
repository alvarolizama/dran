defmodule DranWeb.API.Instance do
  @moduledoc """
  Shared helpers for the REST surface in the single-workspace model
  (W5, contract-instance-visibility-20260919).

  The instance IS the workspace: every endpoint resolves its context through
  `instance_context/0` and ignores legacy `workspace` params (accepted for
  backward compatibility, never trusted to pick another container).

  Read scopes come from `Dran.ContentVisibility` — never a local rule.
  """

  @doc """
  The one context every API call operates on. Returns nil only on an
  un-migrated/empty instance (callers fail closed with 404/422).
  """
  def instance_context do
    Dran.Auth.instance_workspace()
  end

  @doc """
  The context id for write paths (fail-closed: nil when there is no
  instance workspace — the caller must reject the write).
  """
  def instance_context_id do
    case instance_context() do
      %{id: id} -> id
      nil -> nil
    end
  end

  @doc """
  Legacy-param tolerant context resolution: whatever `workspace` value the
  request carries (slug, uuid, garbage), the answer is the instance
  workspace. The param stopped meaning anything in W1.
  """
  def resolve_context(_legacy_param), do: instance_context()

  @doc "The read scope for `conn` (single policy module)."
  def scope_for(conn, kind) do
    Dran.ContentVisibility.resolve(instance_context(), conn.assigns[:user], kind)
  end

  @doc """
  Permitted write fields for pages: `visibility` is client-settable on
  create/update (contract Rules#5) — memories reject it (Rules#6, 422).
  """
  @page_write_fields ~w(title slug body page_type summary tags meta kb_confidence kb_source_url visibility archived pinned)
  def page_write_fields, do: @page_write_fields

  @doc """
  Strips client params down to the permitted write fields, dropping
  server-owned ones (workspace_id, owner, created_by…).
  """
  def permit_page_params(params) do
    Map.take(params, @page_write_fields)
  end

  @doc """
  Extrae el destino de escritura (`scope`) de los params del cliente (W6).

  Devuelve `{scoped?, scope, params}`:

    * `scoped?` distingue "sin `scope`" (la escritura conserva el default /
      el `visibility` legacy de páginas) de un `scope` explícito, que gobierna.
    * `scope` es el valor crudo (`"private"` | `"public"` | `%{"group" => slug}`).
    * `params` ya sin el campo, para que no viaje a los attrs del recurso.

  Con `drop_visibility: true` (páginas) también quita el `visibility` legacy
  cuando hay `scope`, para que el destino declarado no se contradiga.
  """
  def pop_write_scope(params, opts \\ []) do
    if Map.has_key?(params, "scope") do
      scope = params["scope"]

      params =
        params
        |> Map.delete("scope")
        |> then(fn p -> if opts[:drop_visibility], do: Map.delete(p, "visibility"), else: p end)

      {true, scope, params}
    else
      {false, nil, params}
    end
  end
end
