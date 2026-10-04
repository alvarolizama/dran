defmodule DranWeb.API.SkillController do
  @moduledoc """
  La superficie REST del catálogo de skills (contrato de skills remotos).

  * la LECTURA pasa por `Dran.ContentVisibility` con el scope del lector en su
    punto único: un skill ajeno privado es 404, nunca 403 — la existencia no se
    filtra, igual que páginas, goals y planes;
  * el ÍNDICE sirve el catálogo SIN cuerpos y el DETALLE sirve el `SKILL.md`
    montado (frontmatter + body) más el body crudo, para que un cliente que no
    sea Hermes lo escriba o lo pase tal cual;
  * `:slug` es la dirección del wire (inmutable), no un id.
  """

  use DranWeb, :controller

  alias Dran.Skills
  alias Dran.Skills.Skill
  alias DranWeb.API.Instance

  @doc "GET /api/skills — el catálogo que el lector puede leer (sin cuerpos)."
  def index(conn, params) do
    opts =
      [scope: Instance.scope_for(conn, :skill)]
      |> maybe_put(:visibility, visibility_param(params["visibility"]))
      |> maybe_put(:order, order_param(params["order"]))
      |> maybe_put(:limit, parse_int(params["limit"]))

    json(conn, %{data: Skills.index_payload(Skills.list_skills(opts), reader_id(conn))})
  end

  @doc "GET /api/skills/:slug — el skill montado (frontmatter + body)."
  def show(conn, %{"slug" => slug}) do
    case Skills.get_skill(slug, scope: Instance.scope_for(conn, :skill)) do
      nil -> not_found(conn, "skill not found")
      skill -> json(conn, %{data: Skills.show_payload(skill, reader_id(conn))})
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Internals
  # ──────────────────────────────────────────────────────────────────────────

  # El id del lector, resuelto en el punto único de la credencial: `nil` cuando
  # el token no tiene dueño (el admin legacy). Nunca sale del body.
  defp reader_id(conn), do: Dran.Auth.resolve_owner_user_id(conn.assigns[:user])

  # Un valor fuera del vocabulario se IGNORA como filtro de LECTURA (no es una
  # escritura: el fail-closed vive en el changeset, no en un listado).
  defp visibility_param(value) when is_binary(value) do
    if value in Skill.visibilities(), do: value, else: nil
  end

  defp visibility_param(_value), do: nil

  defp order_param(value) when is_binary(value) do
    if value in Skills.orders(), do: value, else: nil
  end

  defp order_param(_value), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_), do: nil
end
