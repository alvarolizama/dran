defmodule DranWeb.SkillLiveTest do
  @moduledoc """
  Gate W3 (contrato de skills remotos): la web del skill.

  - P7: `/skills` lista con el filtro de DESTINO y el de orden en la URL (el
    default no se escribe) y el vacío de la COLECCIÓN sólo aparece sin filtro;
  - P8: el alta y la edición son estado de URL (`?new=true` / `?edit=true`)
    sobre `<.resource_modal>`, con el destino en el header apuntado por
    `form=`, y editar no borra lo que el form no manda (el slug, la versión y
    el hash);
  - P9: Compartir abre el `ShareDialog` de la casa con `resource_type="skill"` y
    el grant se ve al reabrir el diálogo.
  """

  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.Accounts
  alias Dran.Sharing
  alias Dran.Skills

  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  setup do
    Dran.DataCase.ensure_workspace!()
    u = System.unique_integer([:positive])

    {:ok, author} =
      Accounts.create_user(%{
        email: "skill-live-author-#{u}@example.com",
        name: "Author",
        api_token: "tok-skill-live-#{u}"
      })

    {:ok, stranger} =
      Accounts.create_user(%{
        email: "skill-live-stranger-#{u}@example.com",
        name: "Stranger",
        api_token: "tok-skill-stranger-#{u}"
      })

    %{author: author, stranger: stranger}
  end

  describe "la lista (P7)" do
    test "el vacío de la COLECCIÓN ofrece crear", %{author: author, conn: conn} do
      {:ok, view, _html} = live(login(conn, author), ~p"/skills")

      assert has_element?(view, "#skills-index")
      assert has_element?(view, "#skill-new")
      assert has_element?(view, "[data-testid=empty-state]")
    end

    test "lista los legibles con su destino y sin el vacío", %{author: author, conn: conn} do
      private = skill!(author, %{"slug" => "privado"})
      public = skill!(author, %{"slug" => "publico", "visibility" => "public"})

      {:ok, view, _html} = live(login(conn, author), ~p"/skills")

      refute has_element?(view, "[data-testid=empty-state]")
      assert has_element?(view, "#skill-row-#{private.id}")
      assert has_element?(view, "#skill-row-#{public.id}")

      # El destino se anuncia en TODAS las filas, privado incluido: la columna
      # «Destination» del listado no puede quedar vacía para el default.
      assert has_element?(view, "#skill-#{private.id}-visibility", t("Private"))
      assert has_element?(view, "#skill-#{public.id}-visibility", t("Public"))
    end

    test "el filtro de destino vive en la URL y el default no se escribe", %{
      author: author,
      conn: conn
    } do
      private = skill!(author, %{"slug" => "privado"})
      public = skill!(author, %{"slug" => "publico", "visibility" => "public"})

      {:ok, view, _html} = live(login(conn, author), ~p"/skills")

      view
      |> element("#skills-filters")
      |> render_change(%{"visibility" => "public", "order" => "name"})

      # `order=name` es el default: la URL lo OMITE.
      assert_patch(view, ~p"/skills?visibility=public")
      assert has_element?(view, "#skill-row-#{public.id}")
      refute has_element?(view, "#skill-row-#{private.id}")

      view
      |> element("#skills-filters")
      |> render_change(%{"visibility" => "", "order" => "updated"})

      assert_patch(view, ~p"/skills?order=updated")
      assert has_element?(view, "#skill-row-#{private.id}")
    end

    test "con filtro y cero filas NO aparece el vacío de la colección", %{
      author: author,
      conn: conn
    } do
      skill!(author, %{"slug" => "privado"})

      {:ok, view, _html} = live(login(conn, author), ~p"/skills?visibility=public")

      refute has_element?(view, "[data-testid=empty-state]")
      assert has_element?(view, "#skills-filters")
      assert render(view) =~ t("No matches for this filter.")
    end

    test "un filtro forjado se descarta", %{author: author, conn: conn} do
      skill = skill!(author, %{"slug" => "privado"})

      {:ok, view, _html} = live(login(conn, author), ~p"/skills?visibility=basura&order=zzz")

      assert has_element?(view, "#skill-row-#{skill.id}")
    end

    test "lo ajeno privado no se lista ni se abre por URL", %{
      author: author,
      stranger: stranger,
      conn: conn
    } do
      skill = skill!(author, %{"slug" => "privado"})

      {:ok, view, _html} = live(login(conn, stranger), ~p"/skills")

      refute has_element?(view, "#skill-row-#{skill.id}")
      assert has_element?(view, "[data-testid=empty-state]")

      # El detalle redirige a la lista: el slug no confirma existencia.
      assert {:error, {:live_redirect, %{to: "/skills"}}} =
               live(login(conn, stranger), ~p"/skills/privado")
    end

    test "la página no repite la navegación dentro", %{author: author, conn: conn} do
      {:ok, view, _html} = live(login(conn, author), ~p"/skills")

      html = render(view)
      # El sidebar se pinta UNA vez (la del shell): el contenido no trae otra
      # copia de la navegación (§C12.3).
      assert length(String.split(html, ~s(data-nav-block="views"))) == 2
      assert length(String.split(html, ~s(id="sidebar-search-form"))) == 2
    end
  end

  describe "el alta (P8)" do
    test "es estado de URL sobre el modal de la casa, con el destino en el header", %{
      author: author,
      conn: conn
    } do
      {:ok, view, _html} = live(login(conn, author), ~p"/skills")

      view |> element("#skill-new") |> render_click()
      assert_patch(view, ~p"/skills?new=true")

      assert has_element?(view, "#skill-resource-modal")
      # El destino vive en el header, FUERA del form: viaja por el atributo
      # HTML `form`.
      assert has_element?(view, "#skill-visibility-picker input[form='skill-form']")

      # Cerrar el modal vuelve al índice sin query.
      view |> element("#skill-resource-modal-header-actions button") |> render_click()
      assert_patch(view, ~p"/skills")
      refute has_element?(view, "#skill-resource-modal")
    end

    test "crea con el autor como dueño y el destino elegido", %{author: author, conn: conn} do
      {:ok, view, _html} = live(login(conn, author), ~p"/skills?new=true")

      render_submit(view, "save_skill", %{
        "skill" => %{
          "name" => "revision-semanal",
          "description" => "Cómo revisar la semana",
          "body" => "# Pasos",
          "visibility" => "public"
        }
      })

      assert_redirect(view, ~p"/skills/revision-semanal")

      skill = Skills.get_skill("revision-semanal", scope: :all)
      assert skill.owner_user_id == author.id
      assert skill.visibility == "public"
      assert skill.version == 1
      assert skill.description == "Cómo revisar la semana"
    end

    test "el nombre fuera del formato se queda en el form con su error", %{
      author: author,
      conn: conn
    } do
      {:ok, view, _html} = live(login(conn, author), ~p"/skills?new=true")

      html =
        render_submit(view, "save_skill", %{
          "skill" => %{
            "name" => "Bad Name",
            "description" => "d",
            "body" => "# x",
            "visibility" => "private"
          }
        })

      assert html =~ t("must start with a letter and use only a-z, 0-9, _ and -")
      assert Skills.get_skill("Bad Name", scope: :all) == nil
    end
  end

  describe "la edición (P8)" do
    test "editar es `?edit=true` en el detalle y el slug no se toca", %{
      author: author,
      conn: conn
    } do
      skill = skill!(author, %{"slug" => "semanal", "body" => "# uno"})

      {:ok, view, _html} = live(login(conn, author), ~p"/skills/semanal")

      assert has_element?(view, "#skill-body")
      assert has_element?(view, "#skill-content-hash")
      # En la vista no hay control del destino (se administra en Compartir).
      assert has_element?(view, "#skill-share")

      view |> element("#skill-edit") |> render_click()
      assert_patch(view, ~p"/skills/semanal?edit=true")

      assert has_element?(view, "#skill-edit-panel")
      # El nombre se LEE, no se edita: no hay input que lo mande.
      assert has_element?(view, "#skill-name-readonly")
      refute has_element?(view, "#skill-form input[name='skill[name]']")

      render_submit(view, "save_skill", %{
        "skill" => %{"description" => "otra", "body" => "# dos", "visibility" => "public"}
      })

      assert_patch(view, ~p"/skills/semanal")

      updated = Skills.get_skill("semanal", scope: :all)
      assert updated.slug == skill.slug
      assert updated.name == skill.name
      assert updated.description == "otra"
      assert updated.visibility == "public"
      # El cuerpo cambió: versión y hash se mueven.
      assert updated.version == 2
      refute updated.content_hash == skill.content_hash
    end

    test "guardar el MISMO cuerpo no versiona", %{author: author, conn: conn} do
      skill = skill!(author, %{"slug" => "estable", "body" => "# uno"})

      {:ok, view, _html} = live(login(conn, author), ~p"/skills/estable?edit=true")

      render_submit(view, "save_skill", %{
        "skill" => %{"description" => "para probar", "body" => "# uno", "visibility" => "private"}
      })

      same = Skills.get_skill("estable", scope: :all)
      assert same.version == skill.version
      assert same.content_hash == skill.content_hash
    end

    test "borrar desde el detalle vuelve a la lista", %{author: author, conn: conn} do
      skill!(author, %{"slug" => "borrable"})

      {:ok, view, _html} = live(login(conn, author), ~p"/skills/borrable")

      view |> element("#skill-delete") |> render_click()

      assert_redirect(view, ~p"/skills")
      assert Skills.get_skill("borrable", scope: :all) == nil
    end

    test "un tercero no ve compartir ni editar", %{author: author, stranger: stranger, conn: conn} do
      skill!(author, %{"slug" => "publico", "visibility" => "public"})

      {:ok, view, _html} = live(login(conn, stranger), ~p"/skills/publico")

      assert has_element?(view, "#skill-detail")
      refute has_element?(view, "#skill-share")
      refute has_element?(view, "#skill-edit")
      refute has_element?(view, "#skill-delete")
    end
  end

  describe "compartir (P9)" do
    test "el diálogo de la casa comparte y el grant se ve al reabrirlo", %{
      author: author,
      stranger: stranger,
      conn: conn
    } do
      skill = skill!(author, %{"slug" => "equipo"})

      {:ok, view, _html} = live(login(conn, author), ~p"/skills/equipo")

      refute has_element?(view, "#skill-share-dialog")

      view |> element("#skill-share") |> render_click()
      assert has_element?(view, "#skill-share-dialog")
      assert has_element?(view, "#share-user-form")
      assert has_element?(view, "#share-group-form")

      view
      |> element("#share-user-form")
      |> render_submit(%{"user_id" => to_string(stranger.id)})

      assert [share] = Sharing.list_shares("skill", skill.id)
      assert share.user_id == stranger.id
      assert has_element?(view, "#share-row-#{share.id}")

      # Lo compartido queda `shared` y el invitado lo lee.
      assert Skills.get_skill("equipo", scope: :all).visibility == "shared"
      assert Skills.get_skill("equipo", scope: {:reader, stranger.id}).id == skill.id

      # Cerrar y reabrir: el grant sigue ahí (P9).
      view |> element("#skill-share-dialog button[phx-click='close_share']") |> render_click()
      refute has_element?(view, "#skill-share-dialog")

      view |> element("#skill-share") |> render_click()
      assert has_element?(view, "#share-row-#{share.id}")
    end

    test "revocar el grant lo quita", %{author: author, stranger: stranger, conn: conn} do
      skill = skill!(author, %{"slug" => "equipo"})
      {:ok, :shared, _} = Sharing.grant(skill, :skill, {:user, stranger.id})

      {:ok, view, _html} = live(login(conn, author), ~p"/skills/equipo")
      view |> element("#skill-share") |> render_click()

      [share] = Sharing.list_shares("skill", skill.id)

      view |> element("#share-row-#{share.id} button") |> render_click()

      assert Sharing.list_shares("skill", skill.id) == []
    end
  end

  describe "los slugs de la suite (reservados)" do
    test "el alta sigue funcionando para un slug libre", %{author: author, conn: conn} do
      {:ok, view, _html} = live(login(conn, author), ~p"/skills?new=true")

      render_submit(view, "save_skill", %{
        "skill" => %{"name" => "propio", "description" => "mío", "body" => "# p"}
      })

      assert_redirect(view, ~p"/skills/propio")
      assert Skills.get_skill("propio", scope: {:reader, author.id}).name == "propio"
    end

    test "el alta con el nombre de un slug de la suite muestra el error en el campo", %{
      author: author,
      conn: conn
    } do
      {:ok, view, _html} = live(login(conn, author), ~p"/skills?new=true")

      html =
        render_submit(view, "save_skill", %{
          "skill" => %{"name" => "loader", "description" => "d", "body" => "# d"}
        })

      assert html =~ "is reserved by the Dran suite (served by the plugin)"
      # La reserva es la LISTA, no una fila: no se creó nada y el catálogo no
      # tiene un `loader` — la suite viaja con el plugin, no con la instancia.
      assert Skills.get_skill("loader", scope: :all) == nil

      for slug <- Skills.reserved_slugs() do
        assert Skills.reserved_slug?(slug)

        assert {:error, %Ecto.Changeset{}} =
                 Skills.create_skill(%{
                   "name" => slug,
                   "description" => "x",
                   "body" => "# x"
                 })
      end
    end

    test "?edit=true a mano NO abre el panel de edición de un skill AJENO", %{
      author: author,
      stranger: stranger,
      conn: conn
    } do
      other = skill!(stranger, %{"slug" => "ajeno", "visibility" => "public"})

      # El estado de URL no es autorización: el skill público se LEE, pero el
      # panel no se pinta (ni existe el form, así que no hay submit que forjar).
      {:ok, view, _html} = live(login(conn, author), ~p"/skills/#{other.slug}?edit=true")

      refute has_element?(view, "#skill-edit-panel")
      refute has_element?(view, "#skill-form")
      assert has_element?(view, "#skill-body")
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp login(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, user.email)
    |> Plug.Conn.put_session(:is_owner, false)
    |> Plug.Conn.put_session(:workspace_slug, "personal")
  end

  defp skill!(owner, attrs) do
    slug = Map.get(attrs, "slug", "demo")
    base = %{"slug" => slug, "name" => slug, "description" => "para probar", "body" => "# x"}

    {:ok, skill} = Skills.create_skill(Map.merge(base, attrs), owner_user_id: owner.id)
    skill
  end
end
