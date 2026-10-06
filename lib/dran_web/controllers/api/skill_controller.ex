defmodule DranWeb.API.SkillController do
  @moduledoc """
  La superficie REST del catálogo de skills (contrato de skills remotos).

  * la LECTURA pasa por `Dran.ContentVisibility` con el scope del lector en su
    punto único: un skill ajeno privado es 404, nunca 403 — la existencia no se
    filtra, igual que páginas, goals y planes;
  * la ESCRITURA es del DUEÑO (y de los lectores privilegiados): un skill
    `public` ajeno se LEE, no se edita — ahí sí hay 403, porque la existencia ya
    es pública y lo que se niega es la autoridad;
  * el ÍNDICE sirve el catálogo SIN cuerpos y el DETALLE sirve el `SKILL.md`
    montado (frontmatter + body) más el body crudo, para que un cliente que no
    sea Hermes lo escriba o lo pase tal cual;
  * `:slug` es la dirección del wire (inmutable): no hay rename.
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

  @doc """
  POST /api/skills — da de alta un skill con el dueño de la credencial.

  El `owner_user_id` sale del punto único que resolvió la credencial
  (`:api_auth`), nunca del body; `version` y `content_hash` los administra el
  changeset.
  """
  def create(conn, params) do
    {scoped?, scope, params} = Instance.write_scope(conn, params, drop_visibility: true)
    attrs = Instance.permit_skill_params(params)
    owner_id = reader_id(conn)

    case create_with_scope(attrs, owner_id, scoped?, scope, conn.assigns[:user]) do
      {:ok, skill} ->
        conn
        |> put_status(:created)
        |> json(%{data: Skills.show_payload(skill, owner_id)})

      {:error, {:scope, message}} ->
        unprocessable(conn, %{detail: message})

      {:error, {:create, %Ecto.Changeset{} = changeset}} ->
        unprocessable(conn, format_errors(changeset))

      {:error, {:create, reason}} ->
        unprocessable(conn, %{detail: to_string(reason)})
    end
  end

  @doc """
  PUT /api/skills/:slug — edición versionada del cuerpo y del destino.

  El slug no se renombra (`{:error, :rename}`): es la dirección del wire. Un
  skill legible pero ajeno es 403 — la lectura de lo público no da la escritura.
  """
  def update(conn, %{"slug" => slug} = params) do
    {scoped?, write_scope, params} = Instance.write_scope(conn, params, drop_visibility: true)
    attrs = Instance.permit_skill_params(params)

    case writable_skill(slug, conn) do
      nil ->
        not_found(conn, "skill not found")

      :forbidden ->
        forbidden(conn)

      skill ->
        case update_with_scope(skill, attrs, scoped?, write_scope, conn.assigns[:user]) do
          {:ok, updated} ->
            json(conn, %{data: Skills.show_payload(updated, reader_id(conn))})

          {:error, {:rename}} ->
            unprocessable(conn, %{detail: "the slug is the wire address and cannot be renamed"})

          {:error, {:scope, message}} ->
            unprocessable(conn, %{detail: message})

          {:error, {:update, %Ecto.Changeset{} = changeset}} ->
            unprocessable(conn, format_errors(changeset))

          {:error, {:update, reason}} ->
            unprocessable(conn, %{detail: to_string(reason)})
        end
    end
  end

  @doc "DELETE /api/skills/:slug — borra el skill (sólo su dueño)."
  def delete(conn, %{"slug" => slug}) do
    case writable_skill(slug, conn) do
      nil ->
        not_found(conn, "skill not found")

      :forbidden ->
        forbidden(conn)

      skill ->
        {:ok, _} = Skills.delete_skill(skill)
        send_resp(conn, :no_content, "")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Internals
  # ──────────────────────────────────────────────────────────────────────────

  # El insert y la traducción del `scope` van en UNA transacción: un destino que
  # no se puede honrar (grupo inexistente o ajeno) revierte la fila y devuelve
  # 422, nunca un `private` en silencio. La IDENTIDAD viaja hasta la frontera:
  # una credencial atada a un destino (el token de un grupo) sólo honra el suyo.
  defp create_with_scope(attrs, owner_id, scoped?, scope, identity) do
    Dran.Repo.transaction(fn ->
      case Skills.create_skill(attrs, owner_user_id: owner_id) do
        {:ok, skill} -> translate_scope(skill, scope, scoped?, identity)
        {:error, reason} -> Dran.Repo.rollback({:create, reason})
      end
    end)
  end

  defp update_with_scope(skill, attrs, scoped?, scope, identity) do
    Dran.Repo.transaction(fn ->
      case Skills.update_skill(skill, attrs) do
        {:ok, updated} -> translate_scope(updated, scope, scoped?, identity)
        {:error, :rename} -> Dran.Repo.rollback({:rename})
        {:error, reason} -> Dran.Repo.rollback({:update, reason})
      end
    end)
  end

  defp translate_scope(skill, _scope, false, _identity), do: skill

  defp translate_scope(skill, scope, true, identity) do
    case Dran.Sharing.apply_scope(skill, scope, :skill, identity) do
      {:ok, skill} -> skill
      {:error, message} -> Dran.Repo.rollback({:scope, message})
    end
  end

  # La fila que el lector puede ESCRIBIR: `nil` cuando no la puede leer (404, sin
  # fuga de existencia), `:forbidden` cuando la lee pero no es suya (403) y el
  # struct cuando el lector es su dueño o un lector privilegiado.
  defp writable_skill(slug, conn) do
    case Skills.get_skill(slug, scope: Instance.scope_for(conn, :skill)) do
      nil -> nil
      skill -> if can_write?(skill, conn), do: skill, else: :forbidden
    end
  end

  defp can_write?(%Skill{} = skill, conn) do
    case Instance.scope_for(conn, :skill) do
      :all ->
        true

      # Una credencial atada a un grupo lee EXACTAMENTE lo compartido a su
      # grupo: eso ES el contenido del grupo, y el grupo es un principal — lo
      # que puede leer puede reescribirlo (el token de cuenta no cambia).
      {:group, _gid} ->
        true

      {:reader, reader_id} ->
        is_integer(reader_id) and skill.owner_user_id == reader_id
    end
  end

  # `forbidden/1` vive en `DranWeb.ControllerHelpers` (W3, contract
  # auditoria-fixes): este controller lo usaba en privado, ahora es la casa.

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
