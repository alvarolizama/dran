defmodule DranWeb.API.GroupController do
  @moduledoc """
  GET /api/groups — los grupos donde el lector es MIEMBRO (W7, P19).

  El conjunto devuelto es EXACTAMENTE el que `Dran.Sharing.apply_scope/3`
  acepta como destino de `scope: %{"group" => slug}` para el dueño de esta
  credencial (W6): la lista que el cliente ve y los slugs a los que puede
  escribir son el MISMO conjunto. Si divergieran, el agente elegiría un slug
  que la lista dejaba prever y comería un 422.

  El payload es mínimo y estable: `slug` (la identidad que viaja en `scope`)
  y `name`. Nunca ids internos ni la lista de miembros.

  La lectura de grupos es MEMBRESÍA, no visibilidad: un grupo no es contenido
  con `visibility`/`owner_user_id`, así que NO pasa por `Dran.ContentVisibility`
  (la constraint 5 marca la membresía como el filtro correcto).
  """

  use DranWeb, :controller

  alias Dran.Auth
  alias Dran.Sharing

  @doc """
  GET /api/groups — los grupos del lector.

  La identidad es la cuenta dueña del token (el header del perfil es
  atribución, no autorización). Sin identidad resoluble — el token admin
  legado, que no tiene fila en `users` — la respuesta es `[]`: no hay
  membresía que listar y el destino de grupo tampoco se puede validar.
  """
  def index(conn, _params) do
    groups =
      conn.assigns[:user]
      |> Auth.resolve_owner_user_id()
      |> Sharing.list_groups_for_user()

    json(conn, %{data: Enum.map(groups, &%{slug: &1.slug, name: &1.name})})
  end
end
