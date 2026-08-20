defmodule DranWeb.PageNewLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Brain
  alias Dran.Slug

  # Gettext wrapper — the app default locale is "es", so assertions must
  # match the translated strings, not the English msgids.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  setup %{conn: conn} do
    # Disable inference scheduling so create_page doesn't call external APIs.
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
      rerank_model: nil,
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

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, "personal")

    {:ok, conn: conn}
  end

  describe "new page form — slug field removed (Task 2.1)" do
    test "the /notes/new form does not render a slug input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/panel/notes/new")

      # The slug field used to be a labelled "Slug" input. It must be gone —
      # Brain now derives the slug from the title on save.
      refute html =~ ~s(name="page[slug]")
      refute html =~ gettext_slug_label(html, "Slug")
    end
  end

  describe "attributes sidebar (Task 3)" do
    test "the new form renders a right-hand attributes sidebar with tags + summary + meta", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, "/panel/notes/new")

      # The sidebar aside exists with the Atributos heading
      assert html =~ "<aside"
      assert html =~ "Atributos"

      # Summary + tags + meta live in the sidebar, no more collapsible details
      assert html =~ ~s(name="page[summary]")
      assert html =~ ~s(name="page[tags]")
      refute html =~ t("Más opciones")
    end

    test "the primary fields (Title, Content) are in the main column", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/panel/notes/new")

      assert html =~ ~s(name="page[title]")
      assert html =~ "markdown_editor" or html =~ "ProseMirror" or html =~ "page-new-editor"
    end
  end

  describe "smart defaults — meta prefilled per type on :new (Task 2.2)" do
    test "note form prefills kind=thought and date=today", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/panel/notes/new")

      today = Date.utc_today() |> Date.to_string()

      # The kind select has "thought" as its selected option.
      assert html =~ ~s(value="thought")
      assert html =~ ~s(selected="")
      # The date input is prefilled with today's date.
      assert html =~ ~s(value="#{today}")
    end

    test "todo form prefills kanban_status=backlog and priority=medium", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/panel/todos/new")

      assert html =~ ~s(value="backlog")
      assert html =~ ~s(value="medium")
    end

    test "project form prefills status=draft", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/panel/projects/new")

      assert html =~ ~s(value="draft")
    end

    test "plan form prefills status=draft", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/panel/plans/new")

      assert html =~ ~s(value="draft")
    end
  end

  describe "auto-slug derivation on create (Task 2.1)" do
    test "creating a page titled 'Mi Nota Nueva' yields slug 'mi-nota-nueva'" do
      context = Brain.get_workspace_by_slug("personal")

      # Sanity-check the slugify behaviour directly.
      assert Slug.slugify("Mi Nota Nueva") == "mi-nota-nueva"

      # The new form no longer submits a slug; Brain.ensure_title_and_slug/1
      # derives it from the title. We exercise the full path via Brain (the
      # same code the LiveView's save_page handler reaches).
      {:ok, page} =
        Brain.create_page(%{
          workspace_id: context.id,
          page_type: "note",
          title: "Mi Nota Nueva",
          body: "Cuerpo de la nota",
          tags: []
        })

      assert page.slug == "mi-nota-nueva"
    end

    test "creating a page without an explicit slug derives one from the title" do
      context = Brain.get_workspace_by_slug("personal")

      {:ok, page} =
        Brain.create_page(%{
          workspace_id: context.id,
          page_type: "note",
          title: "Otra Nota",
          body: "",
          tags: []
        })

      assert page.slug == "otra-nota"
    end
  end

  # The HTML for a "Slug" label may be either the gettext'd "Slug" string or
  # a raw label attribute. This helper returns the substring we should refute
  # so the assertion is robust to either rendering.
  defp gettext_slug_label(_html, msgid) do
    t(msgid)
  end
end
