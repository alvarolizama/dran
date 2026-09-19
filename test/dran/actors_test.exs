defmodule Dran.ActorsTest do
  @moduledoc """
  `created_by` guarda el IDENTIFICADOR (el correo de la persona, el nombre de la
  key) porque es la clave de unión y lo que devuelve la API. Lo que se pinta en
  pantalla es otra cosa: el nombre de la persona. Eso es lo que se prueba aquí.
  """

  use Dran.DataCase, async: false

  alias Dran.Accounts
  alias Dran.Actors

  defp person(email, name) do
    {:ok, user} =
      Accounts.create_user_with_password(%{
        email: email,
        name: name,
        password: "contrasena-larga-123"
      })

    user
  end

  describe "creator_labels/1 — la etiqueta que se pinta" do
    test "para el correo de una persona devuelve su nombre" do
      user = person("autora@example.com", "Marta Ruiz")

      labels = Actors.creator_labels([user.email])

      assert Actors.creator_label(labels, "autora@example.com") == "Marta Ruiz"
    end

    test "el nombre del usuario manda sobre el display_name del actor" do
      user = person("doble@example.com", "Nombre Vivo")

      # Un display_name viejo en el actor de identidad no debe ganarle al campo
      # que la persona edita en su cuenta.
      actor = Actors.get_actor_by_name(user.email)
      {:ok, _} = Actors.update_actor(actor, %{display_name: "Etiqueta Vieja"})

      labels = Actors.creator_labels([user.email])

      assert Actors.creator_label(labels, user.email) == "Nombre Vivo"
    end

    test "el display_name del actor es el respaldo cuando no hay usuario" do
      {:ok, actor} = Actors.create_actor(%{name: "riel", kind: "agent", display_name: "Riel"})

      labels = Actors.creator_labels([actor.name])

      assert Actors.creator_label(labels, "riel") == "Riel"
    end

    test "lo que no es una persona se queda como está — o con su display_name" do
      labels = Actors.creator_labels(["agent-hermes", "system"])

      # Una key sin display_name conserva su nombre tal cual; el actor de
      # sistema SÍ tiene uno ("System", de ensure_system_actors!/0) y se usa el
      # suyo. En ningún caso se inventa una etiqueta que no exista.
      assert Actors.creator_label(labels, "agent-hermes") == "agent-hermes"
      assert Actors.creator_label(labels, "system") == "System"
    end

    test "un identificador desconocido o nil no rompe el render" do
      labels = Actors.creator_labels(["nadie@example.com", nil])

      assert Actors.creator_label(labels, "nadie@example.com") == "nadie@example.com"
      assert Actors.creator_label(labels, nil) == nil
      assert Actors.creator_label(%{}, "lo-que-sea") == "lo-que-sea"
    end
  end
end
