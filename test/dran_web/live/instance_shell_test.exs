defmodule DranWeb.InstanceShellTest do
  @moduledoc """
  The instance-level pages — `/` (workspaces), `/settings/*` (account) and
  `/admin/*` — share the same sidebar shell as the workspace pages via
  `nav={:instance}`: the sidebar renders the instance nav (Workspaces /
  Account / Admin groups) instead of the workspace nav, and there is no
  topbar anymore.
  """

  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.Accounts

  defp owner_conn(conn, email) do
    case Accounts.get_user_by_email(email) do
      nil ->
        {:ok, _user} =
          Accounts.create_user(%{email: email, name: "Test Owner", is_owner: true})

      _user ->
        :ok
    end

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, email)
    |> Plug.Conn.put_session(:workspace_slug, "personal")
    |> Plug.Conn.put_session(:is_owner, true)
  end

  # {path, active nav key}
  # W1: "/" is the workspace home now (workspace nav, not instance nav) — the
  # dashboard launcher died with the multi-workspace model.
  @pages [
    {"/settings/account", "settings"},
    {"/settings/api-keys", "api_keys"},
    {"/admin/users", "admin_users"},
    {"/admin/groups", "admin_groups"},
    {"/admin/models", "admin_models"},
    {"/admin/system", "admin_system"},
    {"/admin/jobs", "admin_jobs"}
  ]

  for {path, active_key} <- @pages do
    test "#{path} renders the instance sidebar with #{active_key} active", %{conn: conn} do
      conn = owner_conn(conn, "shell_owner@test.dev")
      {:ok, view, _html} = live(conn, unquote(path))

      # The sidebar is present (one shell for the whole app) with the
      # instance nav: Workspaces, Account group, Admin group.
      assert has_element?(view, "aside")
      assert has_element?(view, "a[href='/']")
      assert has_element?(view, "a[href='/settings/account']")
      assert has_element?(view, "a[href='/settings/api-keys']")
      assert has_element?(view, "a[href='/admin/users']")
      assert has_element?(view, "a[href='/admin/system']")

      # The old topbar flow is gone.
      refute has_element?(view, "#app-topbar")

      # The current page's nav link is marked; the others are not.
      assert has_element?(view, "a[aria-current='page'][href='#{unquote(path)}']")

      for {_, key} <- @pages, key != unquote(active_key) do
        refute has_element?(view, "a[aria-current='page'][href='#{path_for(key)}']")
      end
    end
  end

  defp path_for("dashboard"), do: "/"
  defp path_for("settings"), do: "/settings/account"
  defp path_for("api_keys"), do: "/settings/api-keys"
  defp path_for(key), do: "/admin/" <> String.replace(key, "admin_", "")

  test "/admin (overview) renders the instance sidebar with no active item", %{conn: conn} do
    conn = owner_conn(conn, "shell_owner@test.dev")
    {:ok, view, _html} = live(conn, ~p"/admin")

    # La ruta sigue viva (impersonation redirige acá) pero el overview ya no es
    # un item del nav, así que ningún link queda marcado.
    assert has_element?(view, "aside")
    assert has_element?(view, "a[href='/admin/users']")
    refute has_element?(view, "a[aria-current='page']")
  end

  # El drawer es un grid y daisyUI solo declara `grid-auto-columns`: sin acotar la
  # fila, `grid-auto-rows: auto` la infla con el contenido, `main` deja de
  # scrollear por dentro y scrollea el DOCUMENTO — el sidebar y el topbar se van
  # con la rueda (medido: sidebar top -400 con la ventana scrolleada 400px).
  # `lg:grid-rows-1` acota la fila al viewport y es la invariante a mantener: si
  # alguien la quita, el shell vuelve a scrollear entero.
  test "el drawer acota su fila: el scroll vive en main, no en el documento", %{conn: conn} do
    conn = owner_conn(conn, "shell_owner@test.dev")
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ".drawer[class~='lg:grid-rows-1']")
    assert has_element?(view, "main.overflow-y-auto")
  end

  test "the Admin group is hidden for non-owners", %{conn: conn} do
    {:ok, _user} =
      Accounts.create_user(%{email: "shell_plain@test.dev", name: "Plain", is_owner: false})

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "shell_plain@test.dev")
      |> Plug.Conn.put_session(:is_owner, false)

    {:ok, view, _html} = live(conn, ~p"/settings/account")

    assert has_element?(view, "a[href='/']")
    assert has_element?(view, "a[href='/settings/account']")
    refute has_element?(view, "a[href='/admin']")
    refute has_element?(view, "a[href='/admin/users']")
  end

  # El síntoma reportado: desde el shell de CONOCIMIENTO (`/`, `/notes`, `/graph`…)
  # no había NINGUNA ruta a /admin — el sidebar ahí es el nav de conocimiento y el
  # menú de perfil sólo llevaba Workspaces/Profile/API keys/Activity/Instance
  # settings. El grupo Admin vive en el menú de perfil para que /admin sea
  # alcanzable desde cualquier página, no sólo desde /settings/* o /admin/*.
  test "el menú de perfil lleva el grupo Admin completo (owner), desde una página de conocimiento",
       %{conn: conn} do
    conn = owner_conn(conn, "shell_owner@test.dev")
    {:ok, view, _html} = live(conn, ~p"/")

    for path <- ~w(/admin/users /admin/groups /admin/models /admin/system /admin/jobs) do
      assert has_element?(view, "#user-menu a[href='#{path}']"),
             "falta #{path} en el menú de perfil"
    end
  end

  test "el grupo Admin no aparece en el menú de perfil para quien no es owner", %{conn: conn} do
    {:ok, _user} =
      Accounts.create_user(%{email: "shell_plain@test.dev", name: "Plain", is_owner: false})

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "shell_plain@test.dev")
      |> Plug.Conn.put_session(:workspace_slug, "personal")
      |> Plug.Conn.put_session(:is_owner, false)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#user-menu a[href='/settings/account']")
    refute has_element?(view, "#user-menu a[href='/admin/users']")
    refute has_element?(view, "#user-menu a[href='/admin/system']")
  end

  # /settings/instance es una página de INSTANCIA: shell de instancia, sin el nav
  # de conocimiento y sin la caja de búsqueda del sidebar (DESIGN §T2).
  test "/settings/instance usa el shell de instancia, no el de conocimiento", %{conn: conn} do
    conn = owner_conn(conn, "shell_owner@test.dev")
    {:ok, view, _html} = live(conn, ~p"/settings/instance")

    assert has_element?(view, "a[href='/admin/users']")
    assert has_element?(view, "a[href='/admin/groups']")
    # El nav de conocimiento (Journey/Memory, o el buscador del sidebar) no está.
    refute has_element?(view, "a[href='/journey']")
    refute has_element?(view, "#sidebar-search-form")
  end
end
