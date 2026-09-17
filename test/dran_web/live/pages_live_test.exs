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
      # The CTA opens the create modal inside the workspace (patch, not navigate)
      assert html =~ ~s(href="/#{ws.slug}/notes?new=true")
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

    test "card badge shows the page type, ignoring legacy meta.kind", %{conn: conn, ws: ws} do
      # Rows created before M9 carried a `meta.kind` (the collapsed type). The
      # list must render the TYPE label ("Nota"), never the dead kind slug.
      {:ok, plan} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Mi plan",
          body: "",
          page_type: "note",
          meta: %{"kind" => "plan"}
        })

      {:ok, technical} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Nota técnica",
          body: "",
          page_type: "note",
          meta: %{"kind" => "technical"}
        })

      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/notes")

      assert has_element?(view, "[data-testid='page-card-#{plan.slug}']", t("Note"))
      assert has_element?(view, "[data-testid='page-card-#{technical.slug}']", t("Note"))
      refute html =~ t("Plan")
    end

    test "no kind filter dropdown is rendered (the vocabulary is gone)", %{conn: conn, ws: ws} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/notes")

      refute html =~ ~s(data-testid="kind-filters")
      refute html =~ ~s(data-testid="kind-filter-toggle")
      refute html =~ ~s(data-testid="kind-filter-menu")
    end

    test "a legacy ?kind= param is inert — the full list still renders", %{conn: conn, ws: ws} do
      Knowledge.create_page(%{
        workspace_id: ws.id,
        title: "Entrada con kind legacy",
        body: "...",
        page_type: "note",
        meta: %{"kind" => "journal"}
      })

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/notes?kind=journal")

      assert html =~ "Entrada con kind legacy"
    end

    test "a retired type path is a 404, not a redirect to /", %{conn: conn, ws: ws} do
      # ?01 settled: /ideas, /knowledge, /technical, /food are simply gone.
      # The generic /:workspace_slug/:type route matches but resolves to no
      # type, so the LiveView raises NotFoundError. Before this change
      # pages_live.ex redirected to "/", which is what the gate forbids.
      for retired <- ~w(ideas knowledge technical food) do
        assert_raise DranWeb.NotFoundError, fn -> live(conn, "/#{ws.slug}/#{retired}") end
      end

      # …and the exception really is a 404 (not a 500): Plug.Exception.status
      # is what the endpoint uses to pick the response, and ErrorHTML renders
      # the matching status message for it.
      assert Plug.Exception.status(DranWeb.NotFoundError.exception([])) == 404
      assert DranWeb.ErrorHTML.render("404.html", %{}) == "Not Found"
    end

    test "a custom type's declared path is NOT a 404 (workspace-aware gate)", %{
      conn: conn,
      ws: ws
    } do
      # W2: the type gate resolves against the workspace's effective types
      # (4 built-in ∪ custom), so a path a custom type declares is a real
      # route — only paths nobody declares keep 404ing.
      {:ok, ws} =
        Knowledge.update_workspace_settings(ws, %{
          workspace_page_types: [
            %{
              "slug" => "recipe",
              "label" => "Receta",
              "plural" => "Recetas",
              "path" => "recipes",
              "icon" => "hero-beaker",
              "color" => "amber",
              "meta_fields" => []
            }
          ]
        })

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/recipes")
      assert html =~ "Receta"

      # …and an undeclared path still 404s
      assert_raise DranWeb.NotFoundError, fn -> live(conn, "/#{ws.slug}/gadgets") end
    end

    test "a page of a custom type is reachable and listable at its own path", %{
      conn: conn,
      ws: ws
    } do
      {:ok, ws} =
        Knowledge.update_workspace_settings(ws, %{
          workspace_page_types: [
            %{
              "slug" => "recipe",
              "label" => "Receta",
              "plural" => "Recetas",
              "path" => "recipes",
              "icon" => "hero-beaker",
              "color" => "amber",
              "meta_fields" => []
            }
          ]
        })

      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Paella valenciana",
          body: "arroz",
          page_type: "recipe"
        })

      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/recipes")
      assert html =~ "Paella valenciana"
      assert html =~ ~s(href="/#{ws.slug}/recipes/#{page.slug}")

      {:ok, _view, show_html} = live(conn, ~p"/#{ws.slug}/recipes/#{page.slug}")
      assert show_html =~ "Paella valenciana"
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

  describe "new — create a page (resource modal)" do
    test "renders the creation modal (over the list)", %{conn: conn, ws: ws} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/notes?new=true")

      assert html =~ "page-resource-modal"
      assert html =~ "page-new-form-note"
      assert html =~ t("Create")
    end

    test "creation form has no kind select and no duplicate Tags label", %{conn: conn, ws: ws} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/notes?new=true")

      # Replaces "kind select offers the type's registered kinds": the kind
      # vocabulary is gone from the page model, so the creation form must not
      # post `page[meta][kind]` at all.
      refute html =~ ~s(name="page[meta][kind]")

      # the Tags label renders exactly once (component label, not duplicated)
      label_count = Regex.scan(~r/label mb-1 block[^>]*>\s*<\/span>/, html) |> length()

      assert label_count == 0,
             "expected no leftover manual Tags label above tag_input, got #{label_count}"
    end

    test "creation form renders per type, with only the four surviving types",
         %{conn: conn, ws: ws} do
      # Replaces the per-type kind-sample loop: every surviving type renders a
      # creation form under its path segment, and none of them offers kinds.
      for type_path <- ~w(notes entities concepts references) do
        {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/#{type_path}?new=true")

        assert html =~ "page-resource-modal", "no creation modal for #{type_path}"
        refute html =~ ~s(name="page[meta][kind]"), "#{type_path} still offers a kind select"
      end
    end

    test "submitting the form creates the page and redirects to its editor", %{
      conn: conn,
      ws: ws
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/notes?new=true")

      view
      |> form("#page-new-form-note", %{
        # summary deliberately absent: machine-owned field, not in the creation form
        page: %{"title" => "Nota desde form"}
      })
      |> render_submit()

      page = Knowledge.get_page_by_slug("nota-desde-form", ws.id)
      assert page, "page should have been created with a slugified title"

      assert_redirect(view, "/#{ws.slug}/notes/nota-desde-form?edit=true")
    end

    test "close_page_modal patches back to the list", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/notes?new=true")

      render_click(view, "close_page_modal", %{})

      refute has_element?(view, "#page-resource-modal")
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

    test "changing a meta field in the attributes panel autosaves to the db", %{
      conn: conn,
      ws: ws
    } do
      # Replaces the kind autosave coverage: `kind` is gone from the schema, so
      # the equivalent is a real meta field of a surviving type.
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Ubicable",
          body: "cuerpo",
          page_type: "entity",
          meta: %{"location" => "CDMX"}
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/entities/#{page.slug}?edit=true")

      assert has_element?(view, "#entity-editor-attributes-form")

      view
      |> form("#entity-editor-attributes-form", page: %{meta: %{"location" => "Guadalajara"}})
      |> render_change()

      assert Knowledge.get_page(page.id).meta["location"] == "Guadalajara"
    end

    test "tags serialized as a comma string (tag_input hidden field) autosave to the db", %{
      conn: conn,
      ws: ws
    } do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Taggable",
          body: "cuerpo",
          page_type: "note"
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/notes/#{page.slug}")

      # tag_input's hidden input submits "alfa,beta" (a string); the schema
      # casts :tags as {:array, :string} and would reject the changeset
      # without normalization.
      view
      |> element("form#note-editor-attributes-form")
      |> render_change(%{"page" => %{"tags" => "alfa,beta"}})

      assert Knowledge.get_page(page.id).tags == ["alfa", "beta"]
    end

    test "edit mode shows summary read-only (machine-owned field), never an input", %{
      conn: conn,
      ws: ws
    } do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Con resumen",
          body: "cuerpo",
          summary: "Resumen escrito por un agente via las tools",
          page_type: "note"
        })

      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/notes/#{page.slug}?edit=true")

      # The summary IS visible in the attributes sidebar…
      assert html =~ "Resumen escrito por un agente via las tools"
      # …but never as an editable field (machine-owned: REST/backfill only).
      refute has_element?(view, "input[name='page[summary]']")
      refute has_element?(view, "textarea[name='page[summary]']")
    end

    test "creation form modal has no summary input", %{conn: conn, ws: ws} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/notes?new=true")

      assert html =~ "page-new-form-note"
      # Summary is machine-owned — the creation form must not include it.
      refute html =~ "page[summary]"
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
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/notes?new=true")

      view
      |> form("#page-new-form-note", %{page: %{"title" => "Nota atribuida"}})
      |> render_submit()

      page = Knowledge.get_page_by_slug("nota-atribuida", ws.id)
      assert page, "page should have been created"
      assert page.created_by == "test_user"
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
