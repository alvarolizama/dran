defmodule DranWeb.SidebarNavTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  # El rótulo tal como aparece en el HTML renderizado: HEEx escapa el `&`, así
  # que «Goals & Plans» llega al DOM como «Goals &amp; Plans».
  defp rendered_msgid(msgid) do
    msgid |> t() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  alias DranWeb.Layouts

  describe "sidebar_nav (instance pages — no workspace)" do
    test "renders nothing (groups = [])" do
      html =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "dashboard",
          is_owner: true,
          workspace_slug: nil
        })

      # No nav items — instance pages render instance_nav instead.
      refute html =~ t("Dashboard")
      refute html =~ ~s(href="/")
      refute html =~ ~s(href="/admin")
      refute html =~ ~s(href="/settings/account")
      refute html =~ ~s(href="/settings")
      refute html =~ t("Workspace")
    end

    test "renders empty (no mt-auto needed — footer owns it)" do
      html =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "dashboard",
          is_owner: true,
          workspace_slug: nil
        })

      assert html == ""
    end
  end

  describe "instance_nav (el sidebar de las páginas de instancia)" do
    defp instance_nav(assigns \\ %{}) do
      render_component(
        &Layouts.instance_nav/1,
        Map.merge(%{active: "home", is_owner: true}, assigns)
      )
    end

    test "lleva Home, Account (Profile) y el grupo Admin con Settings" do
      html = instance_nav()

      assert html =~ ~s(href="/")
      assert html =~ ~s(href="/settings/account")
      # La configuración de la instancia ES administración (owner-only): vive en
      # el grupo Admin, con la URL del shell de admin.
      assert html =~ ~s(href="/admin/instance")
      assert html =~ t("Settings")
      refute html =~ ~s(href="/settings/instance")

      for path <- ~w(instance users groups models system jobs) do
        assert html =~ ~s(href="/admin/#{path}")
      end
    end

    # El enlace no puede ofrecerse a quien el guard de la ruta rebotaría: la
    # página es del owner y sólo para él se pinta (dueño del grupo Admin).
    test "Settings no se ofrece a quien no es el dueño" do
      html = instance_nav(%{is_owner: false})

      refute html =~ ~s(href="/admin/instance")
      refute html =~ ~s(href="/admin/users")
      assert html =~ ~s(href="/settings/account")
    end

    test "la página se marca activa" do
      html = instance_nav(%{active: "admin_instance"})

      {pos, _} = :binary.match(html, ~s(href="/admin/instance"))
      {end_pos, _} = :binary.match(html, "</a>", scope: {pos, byte_size(html) - pos})
      anchor = binary_part(html, pos, end_pos - pos)
      assert anchor =~ ~s(aria-current="page")
    end
  end

  describe "sidebar_nav grouping" do
    defp workspace_nav(active \\ "home") do
      render_component(&Layouts.sidebar_nav/1, %{
        active: active,
        is_owner: true,
        workspace_slug: "personal",
        workspace_role: "owner"
      })
    end

    defp pos(html, str) do
      {p, _len} = :binary.match(html, str)
      p
    end

    # El HTML del bloque que ABRE en `from` y cierra donde empieza `to`.
    defp slice(html, from, to) do
      html
      |> String.split(from, parts: 2)
      |> List.last()
      |> String.split(to, parts: 2)
      |> List.first()
    end

    # Los marcadores, en el orden dado (el DOM manda, no el texto suelto).
    defp in_order?(html, strs) do
      positions = Enum.map(strs, &pos(html, &1))
      positions == Enum.sort(positions)
    end

    # Posiciones de cada header de grupo (`<summary>`) en orden de DOM.
    defp summary_positions(html) do
      Regex.scan(~r/<summary/, html, return: :index)
      |> List.flatten()
      |> Enum.map(fn {p, _len} -> p end)
    end

    # Etiquetas de grupo en orden, sin markup.
    defp group_labels(html) do
      Regex.scan(~r/<summary[^>]*>(.*?)<\/summary>/s, html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&(&1 |> String.replace(~r/<[^>]*>/, "") |> String.trim()))
    end

    test "las cinco sub-secciones llevan rótulo y las vistas van juntas, en orden" do
      html = workspace_nav()

      # El nav ya no tiene bloques planos: cada bloque es una sub-sección con su
      # rótulo, en orden de DOM.
      assert group_labels(html) == [
               t("Views"),
               rendered_msgid("Goals & Plans"),
               t("Knowledge base"),
               t("Skills"),
               t("Services")
             ]

      views_block = slice(html, ~s(data-nav-block="views"), ~s(data-nav-block="goals-plans"))

      # Inicio → Grafo → Journey → Board, todos dentro de la sub-sección.
      assert in_order?(views_block, [
               ~s(href="/"),
               ~s(href="/graph"),
               ~s(href="/journey"),
               ~s(href="/tasks")
             ])

      refute views_block =~ ~s(href="/workflows")

      # Los objetivos y planes (Goals/Plans) y la memoria NO cuelgan de las vistas.
      refute views_block =~ ~s(href="/goals")
      refute views_block =~ ~s(href="/plans")
      refute views_block =~ ~s(href="/memory")
    end

    test "Clusters y Memory cierran Knowledge base, en ese orden" do
      html = workspace_nav()

      labels = group_labels(html)
      summaries = summary_positions(html)
      kb_index = Enum.find_index(labels, &(&1 == t("Knowledge base")))

      assert refs_pos = pos(html, ~s(href="/references"))
      assert clusters_pos = pos(html, ~s(href="/clusters"))
      assert memory_pos = pos(html, ~s(href="/memory"))

      # clusters y Memory siguen dentro de Knowledge base: después de references.
      assert refs_pos < clusters_pos
      assert clusters_pos < memory_pos
      assert Enum.at(summaries, kb_index) < refs_pos

      # Ninguno abre sub-sección propia: el nav tiene CINCO, no seis
      # (vistas, objetivos y planes, knowledge base, skills y servicios).
      assert length(summaries) == 5
    end

    test "Inicio abre la sub-sección de vistas" do
      html = workspace_nav()

      views_pos = pos(html, ~s(data-nav-block="views"))
      [first_summary | _rest] = summary_positions(html)

      # El rótulo de la sub-sección (su `<summary>`) abre el bloque, y el
      # primer enlace es Inicio.
      assert views_pos < first_summary

      {home_pos, _len} =
        :binary.match(html, ~s(href="/"), scope: {views_pos, byte_size(html) - views_pos})

      assert first_summary < home_pos
    end

    test "active key highlights the right link" do
      html = workspace_nav("memory")

      p = pos(html, ~s(href="/memory"))
      {end_pos, _len} = :binary.match(html, "</a>", scope: {p, byte_size(html) - p})
      anchor = binary_part(html, p, end_pos - p)
      assert anchor =~ ~s(aria-current="page")
      assert anchor =~ "bg-primary/15 text-primary"
    end

    test "Goals y Plans van juntos y el hueco queda antes de Knowledge base" do
      html = workspace_nav()

      views_pos = pos(html, ~s(data-nav-block="views"))
      work_pos = pos(html, ~s(data-nav-block="goals-plans"))
      kb_pos = pos(html, ~s(data-nav-block="knowledge-base"))

      # Bloques hermanos, en orden: vistas → objetivos y planes → Knowledge base. El
      # hueco del nav es el borde antes del knowledge base (los bloques se separan
      # con el gap-4 del contenedor).
      assert views_pos < work_pos
      assert work_pos < kb_pos

      work_block =
        slice(html, ~s(data-nav-block="goals-plans"), ~s(data-nav-block="knowledge-base"))

      # Los dos, y en ese orden.
      assert in_order?(work_block, [~s(href="/goals"), ~s(href="/plans")])

      # La sub-sección de objetivos y planes lleva SU rótulo (uno solo) y ni las
      # vistas ni los tipos de página se cuelan dentro.
      assert length(summary_positions(work_block)) == 1
      assert work_block =~ rendered_msgid("Goals & Plans")
      refute work_block =~ t("Views")
      refute work_block =~ t("Knowledge base")
      refute work_block =~ ~s(href="/journey")
      refute work_block =~ ~s(href="/graph")
      refute work_block =~ ~s(href="/tasks")
      # Memory no vive acá: cierra Knowledge base.
      refute work_block =~ ~s(href="/memory")

      # Ninguno de los dos abre bloque propio; el knowledge base sigue después,
      # con su propia sub-sección etiquetada y Memory al final.
      refute html =~ ~s(data-nav-block="memory")

      kb_block = slice(html, ~s(data-nav-block="knowledge-base"), ~s(data-nav-block="skills"))
      assert length(summary_positions(kb_block)) == 1
      assert kb_block =~ t("Knowledge base")
      assert kb_block =~ ~s(href="/memory")
    end

    test "Servicios cierra el nav, después de Knowledge base y con su badge" do
      html = workspace_nav()

      kb_pos = pos(html, ~s(data-nav-block="knowledge-base"))
      services_pos = pos(html, ~s(data-nav-block="services"))

      # Cuarto bloque, hermano de los otros tres y DESPUÉS de knowledge base.
      assert kb_pos < services_pos

      services_block = slice(html, ~s(data-nav-block="services"), "</nav>")
      assert length(summary_positions(services_block)) == 1
      assert services_block =~ t("Services")
      assert services_block =~ ~s(href="/services")
      # No es un tipo de página: no cuelga de Knowledge base.
      refute kb_block_for(html) =~ ~s(href="/services")
    end

    test "el badge de Servicios cuenta lo expuesto, y se esconde en cero" do
      with_badge =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "services",
          is_owner: true,
          workspace_slug: "personal",
          workspace_role: "owner",
          counts: %{services: 2}
        })

      block = slice(with_badge, ~s(data-nav-block="services"), "</nav>")
      assert block =~ ~s(href="/services")
      assert block =~ "badge badge-sm shell-hide"
      assert block =~ "2"

      without_badge =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "services",
          is_owner: true,
          workspace_slug: "personal",
          workspace_role: "owner",
          counts: %{services: 0}
        })

      refute slice(without_badge, ~s(data-nav-block="services"), "</nav>") =~ "badge"
    end

    test "Skills tiene su propio bloque, con su badge local, entre Knowledge base y Servicios" do
      html = workspace_nav()

      kb_pos = pos(html, ~s(data-nav-block="knowledge-base"))
      skills_pos = pos(html, ~s(data-nav-block="skills"))
      services_pos = pos(html, ~s(data-nav-block="services"))

      assert kb_pos < skills_pos
      assert skills_pos < services_pos

      block = slice(html, ~s(data-nav-block="skills"), ~s(data-nav-block="services"))
      assert length(summary_positions(block)) == 1
      assert block =~ t("Skills")
      assert block =~ ~s(href="/skills")
      # No es un tipo de página ni cuelga de Knowledge base.
      refute kb_block_for(html) =~ ~s(href="/skills")
    end

    test "el badge de Skills cuenta lo del lector, y se esconde en cero" do
      with_badge =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "skills",
          is_owner: true,
          workspace_slug: "personal",
          workspace_role: "owner",
          counts: %{skills: 3}
        })

      block = slice(with_badge, ~s(data-nav-block="skills"), ~s(data-nav-block="services"))
      assert block =~ ~s(href="/skills")
      assert block =~ "badge badge-sm shell-hide"
      assert block =~ "3"

      without_badge =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "skills",
          is_owner: true,
          workspace_slug: "personal",
          workspace_role: "owner",
          counts: %{skills: 0}
        })

      refute slice(without_badge, ~s(data-nav-block="skills"), ~s(data-nav-block="services")) =~
               "badge"
    end

    # El bloque de Knowledge base, para comprobar qué NO vive dentro de él.
    defp kb_block_for(html) do
      slice(html, ~s(data-nav-block="knowledge-base"), ~s(data-nav-block="skills"))
    end
  end

  describe "workspace nav: Activity & Workspace settings NO van en el nav" do
    test "Activity no longer renders as a nav link (vive en #user-menu)" do
      html =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "activity",
          is_owner: false,
          workspace_slug: "personal",
          workspace_role: "viewer"
        })

      refute html =~ ~s(href="/activity")
      refute html =~ t("Activity")
    end

    test "Workspace settings no longer renders as a nav link either" do
      html =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "workspace_settings",
          is_owner: true,
          workspace_slug: "personal",
          workspace_role: "owner"
        })

      refute html =~ ~s(href="/settings")
      refute html =~ t("Workspace settings")
    end
  end

  describe "user_footer menu (workspace-scoped entries)" do
    defp menu(assigns) do
      assigns =
        assigns
        |> Map.put_new(:current_user, "owner@test.dev")
        |> Map.put_new(:user, nil)

      render_component(&Layouts.user_footer/1, assigns)
    end

    test "Home (back to the brain) is always in the menu" do
      for assigns <- [
            %{workspace_slug: nil, is_owner: true},
            %{workspace_slug: "personal", workspace_role: "viewer", is_owner: false}
          ] do
        html = menu(assigns)

        assert html =~ ~s(href="/")
        assert html =~ t("Home")
      end
    end

    test "Home is marked active on the brain home" do
      html = menu(%{workspace_slug: nil, is_owner: true, active: "home"})

      {pos, _} = :binary.match(html, ~s(href="/"))
      {end_pos, _} = :binary.match(html, "</a>", scope: {pos, byte_size(html) - pos})
      anchor = binary_part(html, pos, end_pos - pos)
      assert anchor =~ ~s(aria-current="page")
    end

    # El grupo Admin es lo único que hace /admin alcanzable desde el shell de
    # conocimiento (el sidebar ahí es el nav de conocimiento). Owner-only.
    test "el owner ve el grupo Admin completo; el viewer no ve nada de /admin" do
      owner = menu(%{workspace_slug: "personal", workspace_role: "owner", is_owner: true})
      viewer = menu(%{workspace_slug: "personal", workspace_role: "viewer", is_owner: false})

      # /admin/workspaces murió en W6 (una instancia = un cerebro), así que el
      # grupo Admin del menú son cinco secciones, no seis.
      for path <- ~w(users groups models system jobs) do
        assert owner =~ ~s(href="/admin/#{path}")
        refute viewer =~ ~s(href="/admin/#{path}")
      end

      # El resto del menú no depende del grupo: el viewer conserva sus enlaces.
      assert viewer =~ ~s(href="/settings/account")
      # W3: la pestaña /settings/api-keys murió — la credencial vive en Account.
      refute viewer =~ ~s(href="/settings/api-keys")
    end

    test "workspace owner sees Activity; Settings is the INSTANCE owner's" do
      ws_owner = menu(%{workspace_slug: "personal", workspace_role: "owner", is_owner: false})
      inst_owner = menu(%{workspace_slug: "personal", workspace_role: "owner", is_owner: true})

      assert ws_owner =~ ~s(href="/activity")
      assert ws_owner =~ t("Activity")
      # El rol de WORKSPACE no abre la configuración de la instancia: la ruta es
      # /admin/instance y ese shell es owner-only.
      refute ws_owner =~ ~s(href="/admin/instance")
      assert inst_owner =~ ~s(href="/admin/instance")
      assert inst_owner =~ t("Settings")
      # account links siguen arriba
      assert ws_owner =~ ~s(href="/settings/account")
      assert ws_owner =~ ~s(id="logout-form")
    end

    test "viewer sees Activity but not Settings" do
      html = menu(%{workspace_slug: "personal", workspace_role: "viewer", is_owner: false})

      assert html =~ ~s(href="/activity")
      # Settings is owner-only: viewer gets no admin link at all
      refute html =~ ~s(href="/admin/instance")
    end

    test "instance owner sees Settings regardless of role" do
      html = menu(%{workspace_slug: "personal", workspace_role: "viewer", is_owner: true})

      assert html =~ ~s(href="/admin/instance")
    end

    test "outside a workspace the menu keeps the instance entries (no workspace ones)" do
      owner = menu(%{workspace_slug: nil, is_owner: true})
      viewer = menu(%{workspace_slug: nil, workspace_role: "viewer", is_owner: false})

      # Workspace-scoped: siguen fuera (Activity es del cerebro).
      refute owner =~ "/activity"
      # Settings es de la INSTANCIA: está con o sin workspace, y sólo
      # para el dueño (la ruta vive en /admin/*).
      assert owner =~ ~s(href="/admin/instance")
      assert owner =~ t("Settings")
      refute viewer =~ ~s(href="/admin/instance")

      assert owner =~ ~s(href="/")
      assert owner =~ ~s(href="/settings/account")
      refute owner =~ ~s(href="/settings/api-keys")
    end

    test "the active instance entry is marked" do
      html =
        menu(%{
          workspace_slug: "personal",
          workspace_role: "owner",
          is_owner: true,
          active: "admin_instance"
        })

      {pos, _} = :binary.match(html, ~s(href="/admin/instance"))
      {end_pos, _} = :binary.match(html, "</a>", scope: {pos, byte_size(html) - pos})
      anchor = binary_part(html, pos, end_pos - pos)
      assert anchor =~ ~s(aria-current="page")
    end
  end

  # Las superficies que el owner pidió poder apagar (2026-10-04): Board, Goals,
  # Plans, Memory y Services. Cada una tiene su punto de entrada en el nav y su
  # clave en el tab Features; apagarla quita ESE punto (nunca la ruta ni el
  # dato). El nav resuelve el workspace por slug, así que el flag se prueba
  # contra la fila.
  describe "superficies apagables (memory, board, goals, plans, services)" do
    @surfaces [
      {"memory", "/memory"},
      {"board", "/tasks"},
      {"goals", "/goals"},
      {"plans", "/plans"},
      {"services", "/services"}
    ]

    defp nav_html do
      render_component(&Layouts.sidebar_nav/1, %{
        active: "home",
        is_owner: true,
        workspace_slug: "personal",
        workspace_role: "owner"
      })
    end

    defp set_enabled_features(map) do
      ws = Dran.DataCase.ensure_workspace!()

      ws
      |> Ecto.Changeset.change(enabled_features: map)
      |> Dran.Repo.update!()

      :ok
    end

    test "cada superficie apagada sale del nav y las otras cuatro quedan" do
      for {key, path} <- @surfaces do
        set_enabled_features(%{key => false})
        html = nav_html()

        refute html =~ ~s(href="#{path}"), "#{key} apagada sigue en el nav"

        for {other_key, other_path} <- @surfaces, other_key != key do
          assert html =~ ~s(href="#{other_path}"),
                 "#{other_key} desapareció con #{key} apagada"
        end
      end
    end

    test "prenderlas de nuevo las devuelve al nav" do
      set_enabled_features(Map.new(@surfaces, fn {key, _path} -> {key, true} end))
      html = nav_html()

      for {_key, path} <- @surfaces do
        assert html =~ ~s(href="#{path}")
      end
    end

    # Una instancia que guardó su mapa ANTES de esta ola no tiene estas claves:
    # `feature_enabled?/2` las lee como encendidas (nil → true), así que el nav
    # no queda vacío ni pierde pantallas que ayer estaban.
    test "un mapa viejo, sin las claves nuevas, no apaga ninguna superficie" do
      set_enabled_features(%{"journey" => false, "graph" => true})
      html = nav_html()

      for {_key, path} <- @surfaces do
        assert html =~ ~s(href="#{path}")
      end

      # Lo que SÍ estaba apagado sigue apagado, y lo prendido sigue prendido.
      refute html =~ ~s(href="/journey")
      assert html =~ ~s(href="/graph")
    end
  end
end
