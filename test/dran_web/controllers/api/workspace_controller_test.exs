defmodule DranWeb.API.WorkspaceControllerTest do
  @moduledoc """
  Gate W5 (contract.md): la instancia no admite contenedores extra por API (P6).

  La ola nace de F11 (`POST /api/workspaces` dejaba contenedores huérfanos — y
  hacía ejercible el desempate de `Knowledge.the_instance/0`). Al escribir el
  gate se encontró el verbo hermano de la MISMA clase: `DELETE
  /api/workspaces/:slug` borraba CUALQUIER contenedor, incluida la única
  instancia. Los tres verbos de escritura se retiraron; las lecturas siguen
  (el plugin las usa).
  """

  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Knowledge}

  setup do
    ws = Dran.DataCase.ensure_workspace!()
    unique = System.unique_integer([:positive])

    {:ok, owner} =
      Accounts.create_user(%{email: "ws-owner-#{unique}@dran.test", is_owner: true})

    %{ws: ws, owner: owner}
  end

  defp auth_conn(owner) do
    build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{owner.api_token}")
  end

  test "GET /api/workspaces contesta la instancia (la lectura se queda)", %{ws: ws, owner: owner} do
    conn = get(auth_conn(owner), "/api/workspaces")

    assert %{"data" => [context]} = json_response(conn, 200)
    assert context["id"] == ws.id
  end

  test "POST /api/workspaces ya no existe: no se crean contenedores", %{owner: owner} do
    before = Knowledge.count_workspaces()

    conn = post(auth_conn(owner), "/api/workspaces", %{name: "Otro", slug: "otro-contenedor"})
    assert response(conn, 404) != ""

    assert Knowledge.count_workspaces() == before
  end

  test "PUT y DELETE /api/workspaces/:slug tampoco: la instancia sobrevive", %{
    ws: ws,
    owner: owner
  } do
    conn = put(auth_conn(owner), "/api/workspaces/#{ws.slug}", %{name: "Renombrada"})
    assert response(conn, 404) != ""

    conn = delete(auth_conn(owner), "/api/workspaces/#{ws.slug}")
    assert response(conn, 404) != ""

    assert %{slug: slug, name: name} = Knowledge.get_workspace_by_slug(ws.slug)
    assert slug == ws.slug
    refute name == "Renombrada"
  end
end
