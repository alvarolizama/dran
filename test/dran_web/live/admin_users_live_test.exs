defmodule DranWeb.AdminUsersLiveTest do
  @moduledoc """
  /admin/users — crear una cuenta desde el modal.

  Lo que se prueba aquí es una sola cosa, la que decide si una invitación a un
  workspace sirve para algo: la cuenta que sale del formulario tiene que poder
  ENTRAR. `Dran.Accounts.create_user/1` crea la fila sin contraseña —y sin
  `google_id` no hay forma de autenticarla, `authenticate_user/2` la rechaza
  siempre—, así que el camino de creación de la UI lleva contraseña.
  """

  use DranWeb.ConnCase, async: false

  alias Dran.Accounts

  defp uniq, do: System.unique_integer([:positive])

  # Sesión de dueño de la instancia: el on_mount :require_admin del live_session
  # de /admin comprueba el usuario de la sesión, no un rol de workspace.
  defp owner_conn(conn) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, "test_user")
    |> Plug.Conn.put_session(:workspace_slug, "personal")
    |> Plug.Conn.put_session(:is_owner, true)
  end

  defp open_new_user_modal(view) do
    Phoenix.LiveViewTest.render_click(view, "new_user")
    view
  end

  defp submit_user(view, params) do
    view
    |> Phoenix.LiveViewTest.element("#user-form")
    |> Phoenix.LiveViewTest.render_submit(%{"user" => params})
  end

  # Gettext wrapper for Ecto's messages: `translate_error/1` in
  # core_components.ex resolves them in the "errors" domain, so the assertion
  # reads the catalogue the UI actually uses (locale "en" is the app default).
  defp et(msgid), do: Gettext.dgettext(DranWeb.Gettext, "errors", msgid)

  # HEEx escapes text nodes (an apostrophe in "can't be blank" comes out as
  # &#39;), so any assertion on a message that reaches the DOM compares against
  # the escaped form.
  defp esc(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp modal(view) do
    view |> Phoenix.LiveViewTest.element("#user-modal") |> Phoenix.LiveViewTest.render()
  end

  describe "crear una cuenta" do
    test "la cuenta creada puede entrar con la contraseña que se le puso", %{conn: conn} do
      ws = Dran.DataCase.ensure_workspace!()
      email = "invitado-#{uniq()}@test.dev"
      password = "contrasena-larga-123"

      {:ok, view, _html} = live(owner_conn(conn), ~p"/admin/users")
      open_new_user_modal(view)

      # El modal de alta ofrece la contraseña: es el dato sin el que la cuenta
      # no tiene entrada.
      assert has_element?(view, "#user-form input[name='user[password]']")

      submit_user(view, %{
        "email" => email,
        "name" => "Invitado",
        "password" => password,
        "workspace_ids" => [ws.id]
      })

      user = Accounts.get_user_by_email(email)
      assert user, "la cuenta debería existir tras el submit"
      assert Accounts.user_in_workspace?(user, ws)

      # La prueba de verdad: las credenciales funcionan. Sin esto, invitar a
      # esta cuenta a un workspace es regalarle una puerta sin llave.
      assert {:ok, _} = Accounts.authenticate_user(email, password)
      assert {:error, :unauthorized} = Accounts.authenticate_user(email, "no-es-la-buena")

      # El modal se cierra y no queda abierto con la contraseña dentro.
      refute has_element?(view, "#user-modal")
    end

    test "sin contraseña no se crea nada y el aviso sale en el campo", %{conn: conn} do
      email = "sin-password-#{uniq()}@test.dev"

      {:ok, view, _html} = live(owner_conn(conn), ~p"/admin/users")
      open_new_user_modal(view)

      # Un navegador manda el campo vacío, no lo omite: ese es el caso real y el
      # que tiene que dejar el mensaje a la vista (usar los params tal cual, con
      # claves string, es lo que hace que `used_input?` deje pintarlo).
      submit_user(view, %{"email" => email, "name" => "Sin Clave", "password" => ""})

      refute Accounts.get_user_by_email(email)
      assert has_element?(view, "#user-modal")
      assert modal(view) =~ esc(et("can't be blank"))
    end

    test "una contraseña corta se rechaza en el campo", %{conn: conn} do
      email = "corta-#{uniq()}@test.dev"

      {:ok, view, _html} = live(owner_conn(conn), ~p"/admin/users")
      open_new_user_modal(view)

      submit_user(view, %{"email" => email, "password" => "corta"})

      refute Accounts.get_user_by_email(email)
      assert modal(view) =~ et("should be at least 8 character(s)")
    end

    test "el email repetido se avisa en el campo, no en un flash con inspect", %{conn: conn} do
      email = "repetido-#{uniq()}@test.dev"

      {:ok, _existing} =
        Accounts.create_user_with_password(%{email: email, password: "primera-larga-123"})

      {:ok, view, _html} = live(owner_conn(conn), ~p"/admin/users")
      open_new_user_modal(view)

      submit_user(view, %{"email" => email, "password" => "segunda-larga-123"})

      assert modal(view) =~ esc(et("has already been taken"))
      assert Enum.count(Dran.Accounts.list_users(), &(&1.email == email)) == 1
    end
  end

  describe "editar una cuenta" do
    test "no ofrece la contraseña ni la toca al guardar", %{conn: conn} do
      email = "editar-#{uniq()}@test.dev"

      {:ok, user} =
        Accounts.create_user_with_password(%{email: email, password: "original-larga-123"})

      {:ok, view, _html} = live(owner_conn(conn), ~p"/admin/users")

      Phoenix.LiveViewTest.render_click(view, "edit_user", %{"id" => user.id})

      assert has_element?(view, "#user-form input[name='user[email]']")
      refute has_element?(view, "#user-form input[name='user[password]']")

      # Aunque un cliente mande una contraseña, editando no cambia: no está en
      # el cast de `User.changeset/2`. Cambiar la contraseña de otro vive en su
      # propia cuenta, donde se exige la actual.
      submit_user(view, %{
        "email" => email,
        "name" => "Renombrado",
        "password" => "intento-de-cambio-123"
      })

      updated = Accounts.get_user!(user.id)
      assert updated.name == "Renombrado"
      assert updated.password_hash == user.password_hash
      assert {:ok, _} = Accounts.authenticate_user(email, "original-larga-123")
    end
  end
end
