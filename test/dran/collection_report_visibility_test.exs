defmodule Dran.CollectionReportVisibilityTest do
  @moduledoc """
  Gate W2 (contract.md): colecciones y reports entran en la política única.

  Antes de esta fase las dos tablas declaraban `visibility` sin dueño y sus
  lecturas no filtraban: la columna era una promesa que ninguna query
  consultaba, y un share sobre una de ellas era decorativo. Aquí se fija la
  matriz lector × ítem —dueño, tercero, público, compartido con persona y
  compartido con grupo— en el contexto y en la superficie que lo renderiza,
  más el productor de sistema (un job) que escribe sin dueño.
  """

  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Collections, ContentVisibility, Jobs, Knowledge, Reports, Sharing}

  setup do
    ws = Dran.DataCase.ensure_workspace!()

    {:ok,
     ws: ws, author: member!("author"), reader: member!("reader"), outsider: member!("outsider")}
  end

  # A non-owner member: `instance_role` defaults to "editor", which reads as
  # `{:reader, id}` — the ordinary personal reader.
  defp member!(label) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "#{label}-#{unique}@dran.test",
        api_token: "tok-#{label}-#{unique}"
      })

    user
  end

  # The scope every surface resolves: the ONE policy module, no local rule.
  defp scope(user), do: ContentVisibility.resolve(nil, user, :collections)

  defp uniq, do: System.unique_integer([:positive])

  defp collection!(ws, author, extra \\ %{}) do
    {:ok, collection} =
      Collections.create_collection(
        Map.merge(
          %{
            workspace_id: ws.id,
            name: "Colección #{uniq()}",
            slug: "coleccion-#{uniq()}",
            filters: %{},
            owner_user_id: author.id
          },
          extra
        )
      )

    collection
  end

  defp report!(ws, author, extra \\ %{}) do
    {:ok, report} =
      Reports.create_report(
        Map.merge(
          %{
            workspace_id: ws.id,
            title: "Informe #{uniq()}",
            slug: "informe-#{uniq()}",
            report_type: "log",
            owner_user_id: author.id
          },
          extra
        )
      )

    report
  end

  defp login(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, user.email)
    |> Plug.Conn.put_session(:is_owner, false)
    |> Plug.Conn.put_session(:workspace_slug, "personal")
  end

  describe "colecciones" do
    test "privada: nace con dueño y solo su dueño la lee", %{
      ws: ws,
      author: author,
      reader: reader
    } do
      collection = collection!(ws, author)

      assert collection.visibility == "private"
      assert collection.owner_user_id == author.id

      assert Collections.get_collection_by_slug(collection.slug, ws.id, scope: scope(author)).id ==
               collection.id

      assert Collections.list_collections(ws.id, scope: scope(author)) == [collection]
      assert Collections.list_collections(ws.id, scope: scope(reader)) == []

      assert is_nil(
               Collections.get_collection_by_slug(collection.slug, ws.id, scope: scope(reader))
             )
    end

    test "pública: la lee cualquier tercero", %{ws: ws, author: author, reader: reader} do
      collection = collection!(ws, author, %{visibility: "public"})

      assert Collections.list_collections(ws.id, scope: scope(reader)) == [collection]
      assert Collections.get_collection_by_slug(collection.slug, ws.id, scope: scope(reader))
    end

    test "compartida: el share deja de ser decorativo", %{
      ws: ws,
      author: author,
      reader: reader,
      outsider: outsider
    } do
      collection = collection!(ws, author, %{visibility: "shared"})

      # `shared` sin share no lee nadie más que su dueño.
      assert Collections.list_collections(ws.id, scope: scope(reader)) == []

      {:ok, :shared} = Sharing.share_with_user("collection", collection.id, reader.id)

      assert Collections.get_collection_by_slug(collection.slug, ws.id, scope: scope(reader))
      assert Collections.list_collections(ws.id, scope: scope(reader)) == [collection]

      # El invitado es el invitado, no cualquiera.
      assert Collections.list_collections(ws.id, scope: scope(outsider)) == []
    end

    test "compartida con un grupo: solo sus miembros", %{
      ws: ws,
      author: author,
      reader: reader,
      outsider: outsider
    } do
      collection = collection!(ws, author, %{visibility: "shared"})

      {:ok, group} = Sharing.create_group(%{name: "Lectores #{uniq()}"})
      {:ok, _} = Sharing.add_group_member(group, reader.id)
      {:ok, :shared} = Sharing.share_with_group("collection", collection.id, group.id)

      assert Collections.list_collections(ws.id, scope: scope(reader)) == [collection]
      assert Collections.list_collections(ws.id, scope: scope(outsider)) == []
    end

    test "la superficie /collections solo lista lo que el lector puede leer", %{
      ws: ws,
      author: author,
      reader: reader
    } do
      privada = collection!(ws, author)
      publica = collection!(ws, author, %{visibility: "public"})

      {:ok, author_view, _html} = live(login(build_conn(), author), ~p"/collections")
      assert has_element?(author_view, "[href='/collections/#{privada.slug}']")

      {:ok, reader_view, _html} = live(login(build_conn(), reader), ~p"/collections")
      refute has_element?(reader_view, "[href='/collections/#{privada.slug}']")
      assert has_element?(reader_view, "[href='/collections/#{publica.slug}']")

      # Ni por URL: la colección ajena se lee como inexistente.
      assert {:error, {:live_redirect, %{to: "/collections"}}} =
               live(login(build_conn(), reader), ~p"/collections/#{privada.slug}")

      assert {:ok, _view, html} =
               live(login(build_conn(), author), ~p"/collections/#{privada.slug}")

      assert html =~ privada.name
    end

    test "los resultados de una colección pasan por el mismo filtro de páginas", %{
      ws: ws,
      author: author,
      reader: reader
    } do
      # Dos páginas: una del autor y privada, otra pública. La colección no
      # declara filtro de propietario — el filtro de lectura es el que decide.
      {:ok, privada} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Nota privada del autor #{uniq()}",
          page_type: "note",
          owner_user_id: author.id
        })

      {:ok, publica} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Nota publica #{uniq()}",
          page_type: "note",
          owner_user_id: author.id,
          visibility: "public"
        })

      collection = collection!(ws, author, %{visibility: "public", filters: %{"type" => "note"}})

      {:ok, reader_view, _html} =
        live(login(build_conn(), reader), ~p"/collections/#{collection.slug}")

      assert has_element?(reader_view, "[phx-value-slug='#{publica.slug}']")
      refute has_element?(reader_view, "[phx-value-slug='#{privada.slug}']")

      # El autor sí ve las dos.
      {:ok, author_view, _html} =
        live(login(build_conn(), author), ~p"/collections/#{collection.slug}")

      assert has_element?(author_view, "[phx-value-slug='#{privada.slug}']")
    end
  end

  describe "reports" do
    test "privado: solo su dueño lo lee", %{ws: ws, author: author, reader: reader} do
      report = report!(ws, author)

      assert report.visibility == "private"
      assert report.owner_user_id == author.id
      assert Reports.get_report_by_slug(report.slug, ws.id, scope: scope(author))
      assert is_nil(Reports.get_report_by_slug(report.slug, ws.id, scope: scope(reader)))
      assert is_nil(Reports.get_report(report.id, scope: scope(reader)))
      assert Reports.list_reports(ws.id, scope: scope(reader)) == []
    end

    test "público: lo lee cualquier tercero", %{ws: ws, author: author, reader: reader} do
      report = report!(ws, author, %{visibility: "public"})

      assert Reports.get_report_by_slug(report.slug, ws.id, scope: scope(reader))
      assert Reports.list_reports(ws.id, scope: scope(reader)) == [report]
    end

    test "compartido con una persona y con un grupo", %{
      ws: ws,
      author: author,
      reader: reader,
      outsider: outsider
    } do
      report = report!(ws, author, %{visibility: "shared"})

      assert is_nil(Reports.get_report_by_slug(report.slug, ws.id, scope: scope(reader)))

      {:ok, :shared} = Sharing.share_with_user("report", report.id, reader.id)
      assert Reports.get_report_by_slug(report.slug, ws.id, scope: scope(reader))
      assert is_nil(Reports.get_report_by_slug(report.slug, ws.id, scope: scope(outsider)))

      grupo = report!(ws, author, %{visibility: "shared"})
      {:ok, group} = Sharing.create_group(%{name: "Lectores #{uniq()}"})
      {:ok, _} = Sharing.add_group_member(group, outsider.id)
      {:ok, :shared} = Sharing.share_with_group("report", grupo.id, group.id)

      assert Reports.get_report_by_slug(grupo.slug, ws.id, scope: scope(outsider))
    end

    test "la superficie /reports/:slug no deja leer el informe ajeno", %{
      ws: ws,
      author: author,
      reader: reader
    } do
      privado = report!(ws, author)

      assert {:error, {:live_redirect, %{to: "/activity"}}} =
               live(login(build_conn(), reader), ~p"/reports/#{privado.slug}")

      assert {:ok, _view, html} = live(login(build_conn(), author), ~p"/reports/#{privado.slug}")
      assert html =~ privado.title
    end

    test "el informe de un job es de la instancia: sin dueño, público y legible por un miembro",
         %{
           ws: ws,
           reader: reader
         } do
      # El productor real (Dran.Jobs), con un MFA sin efectos: un informe de
      # job es salida del workspace, no de una persona.
      assert {:ok, report} =
               Jobs.execute(:curator_daily, "manual", {Knowledge, :count_workspaces, []})

      assert report.owner_user_id == nil
      assert report.visibility == "public"
      assert Reports.get_report_by_slug(report.slug, ws.id, scope: scope(reader))
      assert report in Reports.list_reports(ws.id, scope: scope(reader))
    end
  end
end
