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
end
