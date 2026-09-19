defmodule DranWeb.AddedPagesSurfacesTest do
  @moduledoc """
  Una página que se agrega tiene que verse en las dos superficies que reflejan
  el workspace: el **grafo** (un nodo, y contada en sus Type counts) y los
  **badges del sidebar** (el conteo del tipo en el nav).

  Los dos caminos de alta — el editor de la UI (`page_edit.ex`) y los agentes
  por REST (`POST /api/knowledge-pages`) — terminan en `Knowledge.create_page/1`,
  así que estos tests ejercen la cadena completa: alta → payload del grafo (el
  JSON que baja el grafo 3D, vía `GraphCache`) → shell renderizado (badge del
  nav). El camino API se ejerce además por HTTP real (key Bearer), no por la
  función.

  Nota de comportamiento: los counts del sidebar se calculan **al renderizar**
  el shell, así que un alta hecha por un agente con la pestaña abierta mueve el
  badge en la siguiente navegación/recarga, no sola. El test monta el shell de
  nuevo, que es el flujo del usuario.
  """
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.Accounts
  alias Dran.Knowledge
  alias Dran.Repo

  setup %{conn: conn} do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
      timeout: 100,
      schedule_async: false
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    unique = System.unique_integer([:positive])

    {:ok, ws} =
      Knowledge.create_workspace(%{
        name: "Surfaces #{unique}",
        slug: "surfaces-#{unique}"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, ws.slug)
      |> Plug.Conn.put_session(:is_owner, true)

    %{conn: conn, ws: ws, unique: unique}
  end

  test "una página agregada desde la UI sale como nodo del grafo y suma su badge",
       %{conn: conn, ws: ws} do
    {:ok, _view, html} = live(conn, ~p"/#{ws.slug}")
    assert badge(html, "/#{ws.slug}/notes") == 0

    # Alta por el camino de la UI (`page_edit.ex` → Knowledge.create_page/1)
    {:ok, page} =
      Knowledge.create_page(%{
        workspace_id: ws.id,
        title: "Nota agregada",
        page_type: "note"
      })

    graph = graph_payload(conn, ws.slug)

    assert Enum.any?(graph["nodes"], &(&1["slug"] == page.slug))
    assert graph["type_counts"]["note"] == 1

    # El badge del nav cuenta la página en el siguiente render del shell.
    {:ok, _view, html} = live(conn, ~p"/#{ws.slug}")
    assert badge(html, "/#{ws.slug}/notes") == 1
  end

  test "una página agregada por un agente vía API sale como nodo del grafo y suma su badge",
       %{conn: conn, ws: ws, unique: unique} do
    {:ok, _view, html} = live(conn, ~p"/#{ws.slug}")
    assert badge(html, "/#{ws.slug}/notes") == 0

    api_conn =
      api_conn(ws, unique)
      |> post(~p"/api/knowledge-pages", %{
        "workspace" => ws.slug,
        "title" => "Nota del agente",
        "page_type" => "note"
      })

    assert %{"data" => created} = json_response(api_conn, 201)

    graph = graph_payload(conn, ws.slug)

    assert Enum.any?(graph["nodes"], &(&1["slug"] == created["slug"]))
    assert graph["type_counts"]["note"] == 1

    {:ok, _view, html} = live(conn, ~p"/#{ws.slug}")
    assert badge(html, "/#{ws.slug}/notes") == 1
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Payload del grafo tal como lo baja el grafo 3D (`GET /:slug/graph/json`).
  defp graph_payload(conn, slug) do
    conn |> get(~p"/#{slug}/graph/json") |> json_response(200)
  end

  # Conexión de agente: usuario dueño + key con write sobre el workspace.
  defp api_conn(ws, unique) do
    {:ok, owner} =
      Accounts.create_user(%{
        email: "surfaces-owner-#{unique}@example.com",
        name: "Owner",
        is_owner: true
      })

    {:ok, _membership} =
      %Accounts.UserWorkspace{}
      |> Accounts.UserWorkspace.changeset(%{
        user_id: owner.id,
        workspace_id: ws.id,
        role: "owner"
      })
      |> Repo.insert()

    {:ok, key} =
      Accounts.create_api_key(%{
        name: "surfaces-agent-#{unique}",
        workspace_ids: [{ws.id, "write"}],
        created_by_user_id: owner.id
      })

    build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")
  end

  # Badge de conteo del nav para un path: 0 cuando no hay badge (el 0 se oculta).
  defp badge(html, path) do
    {pos, _} = :binary.match(html, ~s(href="#{path}"))
    {end_pos, _} = :binary.match(html, "</a>", scope: {pos, byte_size(html) - pos})
    anchor = binary_part(html, pos, end_pos - pos)

    case Regex.run(~r/badge[^>]*>\s*(\d+)\s*</, anchor) do
      [_, n] -> String.to_integer(n)
      nil -> 0
    end
  end
end
