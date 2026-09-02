defmodule DranWeb.PagesLiveTest do
  @moduledoc """
  Covers the knowledge-base flow from the sidebar: list pages per type,
  open a page (show), create a page (new → save_page), and edit it.
  """
  use DranWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Dran.Knowledge

  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  setup do
    {:ok, ctx} = Knowledge.create_workspace(%{name: "Test WS", slug: "test-ws"})

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, ctx.slug)
      |> Plug.Conn.put_session(:is_owner, true)

    %{conn: conn, ws: ctx}
  end

  describe "index — list pages" do
    test "renders the empty state with a workspace-scoped CTA", %{conn: conn, ws: ws} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/notes")

      assert html =~ t("No notes yet")
      # The CTA must point inside the workspace (not /notes/new)
      assert html =~ ~s(href="/#{ws.slug}/notes/new")
    end

    test "lists created pages with workspace-scoped links", %{conn: conn, ws: ws} do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Mi nota de prueba",
          body: "contenido",
          page_type: "note",
          tags: ["elixir"]
        })

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/notes")

      assert html =~ "Mi nota de prueba"
      assert html =~ ~s(href="/#{ws.slug}/notes/#{page.slug}")
      # Tag chips link to workspace search, not the dead /tags/:tag route
      assert html =~ ~s(href="/#{ws.slug}/search?q=elixir")
    end

    test "renders the kind filter dropdown (collapsed)", %{conn: conn, ws: ws} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/notes")

      assert html =~ ~s(data-testid="kind-filters")
      assert html =~ ~s(data-testid="kind-filter-toggle")
      # Collapsed by default — options only render when open
      refute html =~ ~s(data-testid="kind-filter-menu")
    end

    test "filters the list by ?kind= (single)", %{conn: conn, ws: ws} do
      {:ok, _journal} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Entrada de journal",
          body: "...",
          page_type: "note",
          meta: %{"kind" => "journal"}
        })

      {:ok, _idea} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Idea suelta",
          body: "...",
          page_type: "note",
          meta: %{"kind" => "idea"}
        })

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/notes?kind=journal")

      assert html =~ "Entrada de journal"
      refute html =~ "Idea suelta"
    end

    test "filters the list by ?kind=a,b (multi)", %{conn: conn, ws: ws} do
      {:ok, _journal} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Entrada de journal",
          body: "...",
          page_type: "note",
          meta: %{"kind" => "journal"}
        })

      {:ok, _idea} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Idea suelta",
          body: "...",
          page_type: "note",
          meta: %{"kind" => "idea"}
        })

      {:ok, _quote} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Cita célebre",
          body: "...",
          page_type: "note",
          meta: %{"kind" => "quote"}
        })

      # Two of three kinds selected — the third must not appear
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/notes?kind=journal,idea")

      assert html =~ "Entrada de journal"
      assert html =~ "Idea suelta"
      refute html =~ "Cita célebre"
    end

    test "unknown kinds in the list are dropped", %{conn: conn, ws: ws} do
      Knowledge.create_page(%{
        workspace_id: ws.id,
        title: "Visible igual",
        body: "...",
        page_type: "note"
      })

      # "no-existe" is dropped; empty valid remainder = no filter
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/notes?kind=no-existe")

      assert html =~ "Visible igual"
    end

    test "opening the menu and toggling kinds patches the URL and refilters", %{
      conn: conn,
      ws: ws
    } do
      Knowledge.create_page(%{
        workspace_id: ws.id,
        title: "Solo journal",
        body: "...",
        page_type: "note",
        meta: %{"kind" => "journal"}
      })

      Knowledge.create_page(%{
        workspace_id: ws.id,
        title: "Solo idea",
        body: "...",
        page_type: "note",
        meta: %{"kind" => "idea"}
      })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/notes")

      # Open the dropdown
      view |> element(~s([data-testid="kind-filter-toggle"])) |> render_click()
      assert render(view) =~ ~s(data-testid="kind-filter-menu")

      # Select journal — the other page disappears, URL carries the filter
      view |> element(~s([data-testid="kind-option-journal"])) |> render_click()

      assert_patch view, "/#{ws.slug}/notes?kind=journal"
      html = render(view)
      assert html =~ "Solo journal"
      refute html =~ "Solo idea"

      # Add idea to the selection — both appear
      view |> element(~s([data-testid="kind-option-idea"])) |> render_click()

      assert_patch view, "/#{ws.slug}/notes?kind=journal,idea"
      html = render(view)
      assert html =~ "Solo journal"
      assert html =~ "Solo idea"

      # Clear resets everything
      view |> element(~s([data-testid="kind-clear"])) |> render_click()
      assert_patch view, "/#{ws.slug}/notes"
    end
  end

  describe "show — view a page" do
    test "renders title and body read-only", %{conn: conn, ws: ws} do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Nota visible",
          body: "A note visible through the wiki",
          page_type: "note"
        })

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/notes/#{page.slug}")

      assert html =~ "Nota visible"
      assert html =~ "A note visible through the wiki"
    end
  end

  describe "new — create a page" do
    test "renders the creation form (not the list)", %{conn: conn, ws: ws} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/notes/new")

      assert html =~ "page-new-form-note"
      assert html =~ t("Create Note")
      refute html =~ t("No notes yet")
    end

    test "kind select offers the type's registered kinds, no duplicate Tags label", %{
      conn: conn,
      ws: ws
    } do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/notes/new")

      # kind select posts to page[meta][kind] with raw slugs as values
      assert html =~ ~s(name="page[meta][kind]")
      assert html =~ ~s(value="journal")

      # the Tags label renders exactly once (component label, not duplicated)
      tags_labels = Regex.scan(~r/Etiquetas/, html)
      # locale-dependent: fall back to counting label-text occurrences in any locale
      label_count =
        Regex.scan(~r/label mb-1 block[^>]*>\s*<\/span>/, html) |> length()

      assert label_count == 0,
             "expected no leftover manual Tags label above tag_input, got #{label_count}"
    end

    test "creation form renders per type with its kinds", %{conn: conn, ws: ws} do
      for {type_path, kind_sample} <- [
            {"notes", "journal"},
            {"entities", "person"},
            {"concepts", "technique"},
            {"references", "article"}
          ] do
        {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/#{type_path}/new")

        assert html =~ ~s(name="page[meta][kind]")
        assert html =~ ~s(value="#{kind_sample}"), "missing kind #{kind_sample} for #{type_path}"
      end
    end

    test "submitting the form creates the page and redirects to its editor", %{
      conn: conn,
      ws: ws
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/notes/new")

      view
      |> form("#page-new-form-note", %{
        page: %{"title" => "Nota desde form", "summary" => "resumen"}
      })
      |> render_submit()

      page = Knowledge.get_page_by_slug("nota-desde-form", ws.id)
      assert page, "page should have been created with a slugified title"

      assert_redirect(view, "/#{ws.slug}/notes/nota-desde-form?edit=true")
    end

    test "invalid type falls back to the workspace home", %{conn: conn, ws: ws} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/#{ws.slug}/nonsense/new")
    end
  end

  describe "edit — existing page" do
    test "edit mode renders the edit form", %{conn: conn, ws: ws} do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Editable",
          body: "cuerpo",
          page_type: "note"
        })

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/notes/#{page.slug}?edit=true")

      assert html =~ "page-edit-form"
      assert html =~ "Editable"
    end

    test "renaming the title updates the page", %{conn: conn, ws: ws} do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Antes del rename",
          body: "cuerpo",
          page_type: "note"
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/notes/#{page.slug}?edit=true")

      # The edit form autosaves title changes via phx-change (validate_page)
      view
      |> form("#page-edit-form", %{page: %{"title" => "Después del rename"}})
      |> render_change()

      updated = Knowledge.get_page_by_slug(page.slug, ws.id)
      assert updated.title == "Después del rename"
    end
  end

  describe "attribution — session user stamped on create/update" do
    test "submitting the creation form attributes created_by to the session user", %{
      conn: conn,
      ws: ws
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/notes/new")

      view
      |> form("#page-new-form-note", %{page: %{"title" => "Nota atribuida"}})
      |> render_submit()

      page = Knowledge.get_page_by_slug("nota-atribuida", ws.id)
      assert page, "page should have been created"
      assert page.created_by == "test_user"
      assert page.owner == "system"
    end

    test "saving an existing page stamps updated_by with the session user", %{
      conn: conn,
      ws: ws
    } do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Editable con atribución",
          body: "cuerpo",
          page_type: "note"
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/notes/#{page.slug}?edit=true")

      view
      |> form("#page-edit-form", %{page: %{"title" => "Editable con atribución v2"}})
      |> render_change()

      updated = Knowledge.get_page_by_slug(page.slug, ws.id)
      assert updated.title == "Editable con atribución v2"
      assert updated.updated_by == "test_user"
    end
  end
end
