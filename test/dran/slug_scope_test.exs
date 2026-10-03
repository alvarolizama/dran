defmodule Dran.SlugScopeTest do
  @moduledoc """
  P8 (W4a, contract.md · shaping F30/F31): la unicidad del slug es por
  `(dueño, tipo)` y la dirección canónica resuelve por uuid.

  Cubre las tres piezas del cambio:
    * el índice único del motor por `(COALESCE(owner_user_id, 0), tipo, slug)`;
    * el predicado `taken?` de la app resuelto por dueño, no por workspace;
    * la dirección uuid-primero en la API, con el slug solo de respaldo.
  """

  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Collections, Repo}
  alias Dran.Knowledge.Page

  defp u, do: System.unique_integer([:positive, :monotonic])

  defp user do
    {:ok, user} =
      Accounts.create_user(%{email: "slug-#{u()}@example.com", api_token: "tok#{u()}"})

    user
  end

  setup do
    ws = Dran.DataCase.ensure_workspace!()
    %{ws: ws, alice: user(), bob: user()}
  end

  defp insert_page(ws, owner, slug, type \\ "note") do
    Page.create_changeset(%{
      workspace_id: ws.id,
      title: slug,
      slug: slug,
      page_type: type,
      owner_user_id: owner && owner.id
    })
    |> Repo.insert()
  end

  defp conn_for(user) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{user.api_token}")
  end

  describe "unicidad del motor: (dueño, tipo), no (workspace, slug)" do
    test "dos dueños pueden sostener el mismo slug", %{ws: ws, alice: alice, bob: bob} do
      assert {:ok, a} = insert_page(ws, alice, "viaje")
      assert {:ok, b} = insert_page(ws, bob, "viaje")
      assert a.id != b.id
      assert a.slug == "viaje"
      assert b.slug == "viaje"
    end

    test "un dueño no puede repetir slug en el mismo tipo", %{ws: ws, alice: alice} do
      assert {:ok, _} = insert_page(ws, alice, "viaje", "note")
      assert {:error, cs} = insert_page(ws, alice, "viaje", "note")
      refute cs.valid?
      assert Enum.any?(cs.errors, fn {_field, {msg, _}} -> msg =~ "taken" end)
    end

    test "el mismo slug es libre entre tipos del mismo dueño", %{ws: ws, alice: alice} do
      assert {:ok, _} = insert_page(ws, alice, "viaje", "note")
      assert {:ok, _} = insert_page(ws, alice, "viaje", "entity")
    end

    test "el contenido de sistema (dueño NULL) comparte un solo balde", %{ws: ws} do
      assert {:ok, _} = insert_page(ws, nil, "sistema")
      assert {:error, _cs} = insert_page(ws, nil, "sistema")
    end

    test "una fila de sistema y una con dueño pueden compartir slug", %{ws: ws, alice: alice} do
      assert {:ok, _} = insert_page(ws, nil, "compartido")
      assert {:ok, _} = insert_page(ws, alice, "compartido")
    end
  end

  describe "el predicado `taken?` de la app resuelve por dueño" do
    test "dos dueños conservan el slug base; el dueño que repite recibe sufijo",
         %{ws: ws, alice: alice, bob: bob} do
      {:ok, c1} =
        Collections.create_collection(%{
          "name" => "Favoritos",
          "workspace_id" => ws.id,
          "owner_user_id" => alice.id
        })

      {:ok, c2} =
        Collections.create_collection(%{
          "name" => "Favoritos",
          "workspace_id" => ws.id,
          "owner_user_id" => bob.id
        })

      {:ok, c3} =
        Collections.create_collection(%{
          "name" => "Favoritos",
          "workspace_id" => ws.id,
          "owner_user_id" => alice.id
        })

      assert c1.slug == "favoritos"
      # bob NO colisiona con alice: la unicidad es por dueño.
      assert c2.slug == "favoritos"
      # alice sí colisiona consigo misma → sufijo.
      assert c3.slug != "favoritos"
      assert String.starts_with?(c3.slug, "favoritos-")
    end
  end

  describe "dirección canónica: uuid primero, slug de respaldo" do
    test "GET por uuid y por slug resuelven a la misma página", %{ws: ws, alice: alice} do
      {:ok, page} = insert_page(ws, alice, "canonica")

      by_id = conn_for(alice) |> get("/api/knowledge-pages/#{page.id}") |> json_response(200)
      assert by_id["data"]["id"] == page.id

      by_slug = conn_for(alice) |> get("/api/knowledge-pages/#{page.slug}") |> json_response(200)
      assert by_slug["data"]["id"] == page.id
    end

    test "un segmento forjado (no-uuid) no revienta la query: 404 limpio", %{alice: alice} do
      conn = conn_for(alice) |> get("/api/knowledge-pages/forged-binary-xyz")
      assert json_response(conn, 404)
    end
  end
end
