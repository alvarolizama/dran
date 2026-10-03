defmodule DranWeb.API.GroupsTest do
  @moduledoc """
  Gate W7 (contract-instance-visibility-20260919): los grupos llegan al
  cliente.

  - P19: `GET /api/groups` lista SOLO los grupos donde el lector es miembro —
    el MISMO conjunto con el que W6 autoriza un `scope` de grupo.
  - El slug del grupo es visible y copiable en /admin/groups.
  """

  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Sharing}

  setup do
    ws = Dran.DataCase.ensure_workspace!()
    unique = System.unique_integer([:positive])

    {:ok, alice} =
      Accounts.create_user(%{
        email: "groups-alice-#{unique}@example.com",
        name: "Alice",
        api_token: "tok-alice-#{unique}"
      })

    {:ok, bob} =
      Accounts.create_user(%{
        email: "groups-bob-#{unique}@example.com",
        name: "Bob",
        api_token: "tok-bob-#{unique}"
      })

    %{ws: ws, alice: alice, bob: bob}
  end

  defp auth_conn(user) do
    build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{user.api_token}")
  end

  defp group(name, members) do
    {:ok, group} = Sharing.create_group(%{name: "#{name} #{System.unique_integer([:positive])}"})
    Enum.each(members, fn m -> {:ok, _} = Sharing.add_group_member(group, m.id) end)
    group
  end

  defp listed_slugs(conn) do
    conn = get(conn, "/api/groups")
    assert %{"data" => data} = json_response(conn, 200)
    Enum.map(data, & &1["slug"])
  end

  describe "GET /api/groups (P19)" do
    test "(a) el miembro ve SUS grupos y no los ajenos", %{alice: alice, bob: bob} do
      own = group("Equipo Alice", [alice])
      _other = group("Equipo Bob", [bob])

      conn = get(auth_conn(alice), "/api/groups")
      assert %{"data" => data} = json_response(conn, 200)

      # Exactamente su grupo: el payload lleva slug + name, nunca ids internos.
      assert [%{"slug" => slug, "name" => name}] = data
      assert slug == own.slug
      assert name == own.name
      refute Enum.any?(data, &Map.has_key?(&1, "id"))
    end

    test "(b) dos usuarios distintos ven listas distintas", %{alice: alice, bob: bob} do
      a_group = group("Solo Alice", [alice])
      b_group = group("Solo Bob", [bob])
      both = group("Ambos", [alice, bob])

      alice_slugs = listed_slugs(auth_conn(alice))
      bob_slugs = listed_slugs(auth_conn(bob))

      assert Enum.sort(alice_slugs) == Enum.sort([a_group.slug, both.slug])
      assert Enum.sort(bob_slugs) == Enum.sort([b_group.slug, both.slug])

      refute a_group.slug in bob_slugs
      refute b_group.slug in alice_slugs
    end

    test "(c) sin token → 401" do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("accept", "application/json")

      conn = get(conn, "/api/groups")
      assert %{"errors" => %{"detail" => _}} = json_response(conn, 401)
    end
  end

  describe "/admin/groups — el slug visible y copiable" do
    test "el slug del grupo aparece en el HTML con su botón de copiar" do
      {:ok, group} = Sharing.create_group(%{name: "Panel #{System.unique_integer([:positive])}"})

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user, "test_user")
        |> Plug.Conn.put_session(:is_owner, true)

      {:ok, view, _html} = live(conn, ~p"/admin/groups")

      # `has_element?` con filtro de texto: el slug está en el nodo, no como
      # texto crudo suelto en la página.
      assert has_element?(view, "#group-slug-#{group.id}", group.slug)
      assert has_element?(view, "#copy-group-slug-#{group.id}")
    end
  end
end
