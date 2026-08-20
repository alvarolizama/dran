defmodule DranWeb.SessionControllerTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Brain
  alias DranWeb.Plugs.Auth

  # The context selector cookie is signed with the endpoint's signing salt.
  # We test the full cycle: switch context → cookie set → new conn restores it.

  setup %{conn: conn} do
    # Ensure we have at least two contexts to switch between
    personal = Brain.get_workspace_by_slug("personal")

    work = Brain.get_workspace_by_slug("work")

    if is_nil(work) do
      {:ok, _work} = Brain.create_workspace(%{name: "Work", slug: "work"})
    end

    work = Brain.get_workspace_by_slug("work")

    # Log in and set initial context to "personal".
    # Set secret_key_base so signed cookies work in tests.
    secret_key_base = DranWeb.Endpoint.config(:secret_key_base)

    conn =
      conn
      |> then(&%{&1 | secret_key_base: secret_key_base})
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, "personal")

    {:ok, conn: conn, personal: personal, work: work}
  end

  describe "POST /context — switch_context" do
    test "sets the signed dran_last_workspace cookie", %{conn: conn} do
      conn =
        post(conn, ~p"/panel/workspace", %{"workspace_slug" => "work"})

      # The session has the new context
      assert Plug.Conn.get_session(conn, :workspace_slug) == "work"

      # The signed cookie is in the response
      assert conn.resp_cookies["dran_last_workspace"]
    end

    test "redirects back to referer or /notes", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("referer", "/panel/notes")
        |> post(~p"/panel/workspace", %{"workspace_slug" => "work"})

      assert redirected_to(conn, 302) == "/panel/notes"
    end

    test "without workspace_slug shows error flash", %{conn: conn} do
      conn = post(conn, ~p"/panel/workspace", %{})
      assert redirected_to(conn, 302) == "/panel/notes"
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
  end

  describe "page counts in context selector" do
    test "page_counts_by_workspace returns map of workspace_id => count", %{
      personal: personal
    } do
      # Create a couple of pages in the personal context
      Brain.create_page(%{
        workspace_id: personal.id,
        title: "Count Test 1",
        body: "",
        page_type: "note"
      })

      Brain.create_page(%{
        workspace_id: personal.id,
        title: "Count Test 2",
        body: "",
        page_type: "note"
      })

      counts = Brain.page_counts_by_workspace()

      assert counts[personal.id] >= 2
    end
  end
end
