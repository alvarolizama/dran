defmodule DranWeb.SmartCollectionLiveTest do
  @moduledoc """
  Gate W3 (P5): collections es una superficie CON destino y muestra la MISMA
  píldora que pages, goals, plans y memory — en el card del índice y en el
  detalle — y su lectura sigue pasando por la política única: una colección
  ajena privada no se lista, no se abre y no imprime el valor crudo de la
  columna.
  """

  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Collections, Knowledge}

  # Gettext wrapper. English is the app default locale, so the msgid is what the
  # app renders unless a test pins another locale.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  # Un lector no-owner: `instance_role` default "editor" se resuelve como
  # `{:reader, id}` — el lector personal ordinario.
  defp member!(label) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "#{label}-#{unique}@dran.test",
        api_token: "tok-#{label}-#{unique}"
      })

    user
  end

  defp login(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, user.email)
    |> Plug.Conn.put_session(:is_owner, false)
    |> Plug.Conn.put_session(:workspace_slug, "personal")
  end

  defp uniq, do: System.unique_integer([:positive])

  defp collection!(owner, extra \\ %{}) do
    workspace = Knowledge.get_workspace_by_slug("personal")

    {:ok, collection} =
      Collections.create_collection(
        Map.merge(
          %{
            workspace_id: workspace.id,
            name: "Colección #{uniq()}",
            slug: "coleccion-#{uniq()}",
            filters: %{},
            owner_user_id: owner.id
          },
          extra
        )
      )

    collection
  end

  test "el índice y el detalle muestran el destino con la píldora compartida" do
    owner = member!("coll-owner")
    collection = collection!(owner, %{visibility: "public"})

    {:ok, index_view, _html} = live(login(build_conn(), owner), ~p"/collections")

    assert has_element?(
             index_view,
             "#collection-visibility-#{collection.id}",
             t("Public")
           )

    {:ok, show_view, _html} =
      live(login(build_conn(), owner), ~p"/collections/#{collection.slug}")

    assert has_element?(show_view, "#collection-visibility-badge", t("Public"))
    # El destino de una colección es SUYO: nunca se marca como heredado.
    refute has_element?(show_view, "#collection-visibility-badge[data-inherited='true']")
  end

  test "una colección privada no anuncia su nivel y el valor crudo no se imprime" do
    owner = member!("coll-private")
    collection = collection!(owner)

    {:ok, view, _html} = live(login(build_conn(), owner), ~p"/collections")

    refute has_element?(view, "#collection-visibility-#{collection.id}")
    refute render(view) =~ ">private<"

    {:ok, show_view, _html} =
      live(login(build_conn(), owner), ~p"/collections/#{collection.slug}")

    refute has_element?(show_view, "#collection-visibility-badge")
    refute render(show_view) =~ ">private<"
  end

  test "una colección ajena privada no se lista ni se abre" do
    owner = member!("coll-mine")
    stranger = member!("coll-stranger")

    mine = collection!(owner, %{visibility: "public"})
    theirs = collection!(stranger)

    {:ok, view, _html} = live(login(build_conn(), owner), ~p"/collections")

    assert has_element?(view, "#collection-visibility-#{mine.id}")
    refute has_element?(view, "#collection-visibility-#{theirs.id}")

    # Abrir el slug a mano tampoco: navega fuera, sin decir que existe.
    assert {:error, {:live_redirect, %{to: "/collections"}}} =
             live(login(build_conn(), owner), ~p"/collections/#{theirs.slug}")
  end

  test "una colección compartida conmigo se lista y traduce su destino" do
    owner = member!("coll-shared")
    reader = member!("coll-reader")
    collection = collection!(owner, %{visibility: "shared"})

    {:ok, _} = Dran.Sharing.share_with_user("collection", collection.id, reader.id)

    {:ok, view, _html} = live(login(build_conn(), reader), ~p"/collections")

    assert has_element?(view, "#collection-visibility-#{collection.id}", t("Shared"))
  end
end
