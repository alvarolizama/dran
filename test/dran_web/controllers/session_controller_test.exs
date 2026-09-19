defmodule DranWeb.SessionControllerTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Knowledge
  alias DranWeb.Plugs.Auth

  # The context selector cookie is signed with the endpoint's signing salt.
  # We test the full cycle: switch context → cookie set → new conn restores it.

  setup %{conn: conn} do
    # Ensure we have at least two contexts to switch between
    personal = Knowledge.get_workspace_by_slug("personal")

    work = Knowledge.get_workspace_by_slug("work")

    if is_nil(work) do
      {:ok, _work} = Knowledge.create_workspace(%{name: "Work", slug: "work"})
    end

    work = Knowledge.get_workspace_by_slug("work")

    # Log in and set initial context to "personal".
    # Set secret_key_base so signed cookies work in tests.
    secret_key_base = DranWeb.Endpoint.config(:secret_key_base)

    conn =
      conn
      |> then(&%{&1 | secret_key_base: secret_key_base})
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, "personal")
      |> Plug.Conn.put_session(:is_owner, true)

    {:ok, conn: conn, personal: personal, work: work}
  end

  describe "POST /context — switch_context" do
    test "sets the signed dran_last_workspace cookie", %{conn: conn} do
      conn =
        post(conn, ~p"/workspace", %{"workspace_slug" => "work"})

      # The session has the new context
      assert Plug.Conn.get_session(conn, :workspace_slug) == "work"

      # The signed cookie is in the response
      assert conn.resp_cookies["dran_last_workspace"]
    end

    test "redirects back to referer or /notes", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("referer", "/")
        |> post(~p"/workspace", %{"workspace_slug" => "work"})

      assert redirected_to(conn, 302) == "/"
    end

    test "without workspace_slug shows error flash", %{conn: conn} do
      conn = post(conn, ~p"/workspace", %{})
      assert redirected_to(conn, 302) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "required"
    end
  end

  describe "cookie-based context restoration" do
    test "fetch_workspace_cookie restores context from signed cookie when session has none", %{
      conn: conn
    } do
      # Simulate: user previously switched to "work", cookie was set.
      # We use put_workspace to set the signed cookie, then extract it.
      secret_key_base = DranWeb.Endpoint.config(:secret_key_base)

      # Step 1: set the context via put_workspace, which sets the signed cookie
      conn_with_cookie =
        %{conn | secret_key_base: secret_key_base}
        |> Plug.Conn.put_session(:workspace_slug, nil)
        |> Auth.put_workspace("work")
        |> Plug.Conn.send_resp(200, "")

      # Extract the signed cookie value from the response
      signed_cookie = conn_with_cookie.resp_cookies["dran_last_workspace"].value

      # Step 2: build a fresh conn that carries the signed cookie as an
      # incoming request cookie, with no workspace_slug in the session.
      fresh_conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> then(&%{&1 | secret_key_base: secret_key_base})
        |> Plug.Conn.put_session(:user, "test_user")
        |> Plug.Test.put_req_cookie("dran_last_workspace", signed_cookie)
        |> Auth.fetch_workspace_cookie([])

      assert Plug.Conn.get_session(fresh_conn, :workspace_slug) == "work"
    end

    test "fetch_workspace_cookie does nothing when session already has context", %{conn: conn} do
      # Session already has "personal" — cookie should be ignored.
      # Even if a signed cookie for "work" is present, the session takes precedence.
      secret_key_base = DranWeb.Endpoint.config(:secret_key_base)

      conn_with_cookie =
        %{conn | secret_key_base: secret_key_base}
        |> Auth.put_workspace("work")
        |> Plug.Conn.send_resp(200, "")

      signed_cookie = conn_with_cookie.resp_cookies["dran_last_workspace"].value

      conn =
        conn
        |> Plug.Test.put_req_cookie("dran_last_workspace", signed_cookie)
        |> Auth.fetch_workspace_cookie([])

      assert Plug.Conn.get_session(conn, :workspace_slug) == "personal"
    end

    test "fetch_workspace_cookie does nothing when no cookie present", %{conn: conn} do
      conn =
        conn
        |> Auth.fetch_workspace_cookie([])

      # Session context is preserved (personal from setup)
      assert Plug.Conn.get_session(conn, :workspace_slug) == "personal"
    end

    test "the :browser pipeline restores it (regression: the plug was wired to a name that no longer exists)",
         %{conn: conn} do
      secret_key_base = DranWeb.Endpoint.config(:secret_key_base)

      signed_cookie =
        %{conn | secret_key_base: secret_key_base}
        |> Plug.Test.init_test_session(%{})
        |> Auth.put_workspace("work")
        |> Plug.Conn.send_resp(200, "")
        |> Map.fetch!(:resp_cookies)
        |> Map.fetch!("dran_last_workspace")
        |> Map.fetch!(:value)

      # A session with NO workspace slug: only the plug in the :browser pipeline
      # can set it. It used to be wired as `:fetch_context_cookie`, which
      # DranWeb.Plugs.Auth.call/2 does not implement, so it fell through to the
      # catch-all and did nothing at all.
      fresh =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> then(&%{&1 | secret_key_base: secret_key_base})
        |> Plug.Test.put_req_cookie("dran_last_workspace", signed_cookie)
        |> get(~p"/")

      # No session user, so the request ends at /login — but it went THROUGH the
      # pipeline, and that is what the cookie had to survive.
      assert redirected_to(fresh) == "/login"
      assert Plug.Conn.get_session(fresh, :workspace_slug) == "work"
    end
  end

  describe "page counts in context selector" do
    test "page_counts_by_workspace returns map of workspace_id => count", %{
      personal: personal
    } do
      # Create a couple of pages in the personal context
      Knowledge.create_page(%{
        workspace_id: personal.id,
        title: "Count Test 1",
        body: "",
        page_type: "note"
      })

      Knowledge.create_page(%{
        workspace_id: personal.id,
        title: "Count Test 2",
        body: "",
        page_type: "note"
      })

      counts = Knowledge.page_counts_by_workspace()

      assert counts[personal.id] >= 2
    end
  end

  describe "sidebar workspace selector" do
    # Regression: the selector form posted the field as "context_slug" — a
    # leftover from the contexts→workspaces rename — while
    # SessionController.switch_workspace/2 reads "workspace_slug". Every switch
    # therefore fell through to the catch-all ("Context slug is required") and
    # the active workspace never changed. The two names must stay in sync.
    test "posts the field name the switch controller reads" do
      html =
        render_component(&DranWeb.Layouts.workspace_selector/1, %{
          workspaces: [
            %{id: "1", name: "Personal", slug: "personal"},
            %{id: "2", name: "Work", slug: "work"}
          ],
          workspace_slug: "personal",
          page_counts: %{}
        })

      assert html =~ ~s(action="/workspace")
      assert html =~ ~s(name="workspace_slug")
      refute html =~ ~s(name="context_slug")
    end

    test "desambiguates two workspaces that share a name" do
      html =
        render_component(&DranWeb.Layouts.workspace_selector/1, %{
          workspaces: [
            %{id: "1", name: "Personal", slug: "personal"},
            %{id: "2", name: "Personal", slug: "personal-3f9a2b"},
            %{id: "3", name: "Trabajo", slug: "trabajo"}
          ],
          workspace_slug: "personal",
          page_counts: %{}
        })

      # Now that the name is not unique, a repeated one has to show the slug —
      # two identical rows in a dropdown is a coin toss.
      assert html =~ "Personal · personal (0)"
      assert html =~ "Personal · personal-3f9a2b (0)"

      # A unique name stays clean: no noise added where there is no ambiguity.
      assert html =~ "Trabajo (0)"
      refute html =~ "Trabajo · trabajo"
    end
  end

  describe "POST /setup — first-run onboarding" do
    # No users at all (that is what /setup is for) and no pre-made workspaces,
    # so the owner's personal workspace is created by this very flow.
    @tag :no_default_workspace
    test "creates the owner WITH its personal workspace and lands there", %{conn: conn} do
      conn = get(conn, ~p"/setup")
      csrf = conn.private.plug_session["_csrf_token"]

      conn =
        post(conn, ~p"/setup", %{
          "_csrf_token" => csrf,
          "setup" => %{
            "email" => "founder@example.com",
            "password" => "supersecret123",
            "password_confirmation" => "supersecret123"
          }
        })

      assert redirected_to(conn, 302) == "/"

      owner = Dran.Accounts.get_user_by_email("founder@example.com")
      assert owner.is_owner

      personal = Dran.Accounts.personal_workspace(owner)
      assert personal
      assert personal.visibility == "private"
      refute personal.is_default
      assert Dran.Accounts.user_role_in_workspace(owner, personal) == "owner"

      # The onboarding default landing: the account's own personal workspace.
      assert owner.default_workspace_slug == personal.slug
      assert get_session(conn, "workspace_slug") == personal.slug
    end

    @tag :no_default_workspace
    test "an instance with no users sends visitors to /setup" do
      # A FRESH conn: this file's setup already logs test_user in, and a session
      # user skips the first-run branch entirely.
      conn = Phoenix.ConnTest.build_conn()

      # No users at all: /setup is the only door in. This is exactly where
      # DRAN_RESET=1 leaves the instance, so it has to happen by itself.
      refute Dran.Accounts.any_users?()
      assert redirected_to(get(conn, ~p"/")) == "/setup"
      assert redirected_to(get(conn, ~p"/settings/account")) == "/setup"
    end

    test "an instance with users sends anonymous visitors to /login" do
      conn = Phoenix.ConnTest.build_conn()

      # The ConnCase fixture created test_user, so the instance is set up.
      assert Dran.Accounts.any_users?()
      assert redirected_to(get(conn, ~p"/")) == "/login"
    end
  end
end
