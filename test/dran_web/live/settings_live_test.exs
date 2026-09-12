defmodule DranWeb.SettingsLiveTest do
  use DranWeb.ConnCase, async: false

  import Ecto.Query

  alias Dran.Accounts
  alias Dran.Knowledge

  # Gettext wrapper — the app default locale is "es", so assertions must
  # match the translated strings, not the English msgids.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  setup %{conn: conn} do
    # Create (or fetch) an admin user whose email matches the session value the
    # router's require_admin plug looks up. The /settings route is admin-only.
    case Accounts.get_user_by_email("test_user") do
      nil ->
        {:ok, _user} =
          Accounts.create_user(%{email: "test_user", name: "Test Admin", is_owner: true})

      _ ->
        :ok
    end

    # Log in — init_test_session is needed because ConnCase doesn't pipe
    # through the browser pipeline that Auth expects.
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, "personal")
      |> Plug.Conn.put_session(:is_owner, true)

    {:ok, conn: conn}
  end

  test "the agents tab renders agents with their inline key management", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/agents")

    # un solo tab de gestión: agentes, sin sección de API keys global
    assert html =~ t("Agents")
    assert html =~ t("No agents yet — create one with the form above.")
    refute html =~ ~s(id="create-api-key-form")
    refute html =~ ~s(phx-click="open_api_key_modal")
  end

  test "creating an agent key from its row reveals the token once", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, ws} =
      Knowledge.create_workspace(%{name: "Matrix #{unique}", slug: "matrix-#{unique}"})

    {:ok, actor} =
      Dran.Actors.create_actor(%{name: "hermes-#{unique}", kind: "agent"})

    {:ok, view, _html} = live(conn, ~p"/settings/agents")

    # Create key opens the workspace×level modal first
    html =
      view
      |> element("#actor-#{actor.id} button[phx-click='open_create_key_modal']")
      |> render_click()

    assert html =~ ~s(id="create-key-form")

    # Submit: ws checked read
    html =
      view
      |> element("#create-key-form")
      |> render_submit(%{
        "key" => %{
          "actor_id" => actor.id,
          "workspaces" => %{ws.id => %{"enabled" => "true", "level" => "read"}}
        }
      })

    # The one-time reveal card shows the full token + copy button
    assert html =~ ~s(id="revealed-api-key-card")
    assert html =~ ~s(id="copy-revealed-key-btn")

    # The agent row now shows the masked prefix instead of the create button
    refute html =~ ~s(phx-click="open_create_key_modal")
    assert html =~ "••••"
  end

  test "editing an agent key's access matrix updates workspaces and levels", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, ws_a} =
      Knowledge.create_workspace(%{name: "Alpha #{unique}", slug: "alpha-#{unique}"})

    {:ok, ws_b} =
      Knowledge.create_workspace(%{name: "Beta #{unique}", slug: "beta-#{unique}"})

    user = Accounts.get_user_by_email("test_user")

    {:ok, actor} =
      Dran.Actors.create_actor(%{name: "editor-#{unique}", kind: "agent"})

    {:ok, key} =
      Accounts.create_api_key(%{
        name: actor.name,
        workspace_ids: [{ws_a.id, "read"}],
        created_by_user_id: user.id,
        actor_id: actor.id
      })

    {:ok, view, _html} = live(conn, ~p"/settings/agents")

    html =
      view
      |> element("#actor-#{actor.id} button[phx-click='edit_agent_access']")
      |> render_click()

    assert html =~ ~s(id="edit-key-form")

    html =
      view
      |> element("#edit-key-form")
      |> render_submit(%{
        "key" => %{
          "workspaces" => %{
            ws_a.id => %{"enabled" => "true", "level" => "write"},
            ws_b.id => %{"enabled" => "true", "level" => "read"}
          }
        }
      })

    assert html =~ t("Agent access updated")

    # token preserved — the matrix edit never rotates the credential
    token = key.token
    key = Dran.Repo.preload(Dran.Repo.get!(Dran.Accounts.ApiKey, key.id), :api_key_workspaces)

    levels = Map.new(key.api_key_workspaces, &{&1.workspace_id, &1.access_level})
    assert levels[ws_a.id] == "write"
    assert levels[ws_b.id] == "read"

    assert Accounts.valid_api_key?(token) != :error
  end

  test "revoking a key from the list marks it revoked", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, ctx} =
      Knowledge.create_workspace(%{name: "Keys #{unique}", slug: "keys-#{unique}"})

    user = Accounts.get_user_by_email("test_user")

    {:ok, key} =
      Accounts.create_api_key(%{
        name: "Revocable",
        workspace_ids: [{ctx.id, "read"}],
        created_by_user_id: user.id
      })

    # key ligada a un agente para que aparezca en su fila
    {:ok, actor} = Dran.Actors.create_actor(%{name: "revocable-#{unique}", kind: "agent"})

    {:ok, key} =
      Accounts.create_api_key(%{
        name: "Revocable",
        workspace_ids: [{ctx.id, "read"}],
        created_by_user_id: user.id,
        actor_id: actor.id
      })

    {:ok, view, _html} = live(conn, ~p"/settings/agents")

    html =
      view
      |> element("#actor-#{actor.id} button[phx-click='revoke_api_key']")
      |> render_click()

    assert Accounts.valid_api_key?(key.token) == :error

    # revocada la única key: la fila vuelve a ofrecer Create key
    assert html =~ ~s(phx-click="open_create_key_modal")
  end

  test "copy_api_key_prefix of ANOTHER user's key is rejected without leaking the prefix", %{
    conn: _conn
  } do
    unique = System.unique_integer([:positive])

    {:ok, ctx} =
      Knowledge.create_workspace(%{name: "Foreign #{unique}", slug: "foreign-#{unique}"})

    # A NON-owner session user (the /settings/api_keys route is any-user).
    {:ok, non_owner} =
      Accounts.create_user(%{email: "plain-user-#{unique}@example.com", name: "Plain"})

    {:ok, _} = Accounts.add_user_to_workspace(non_owner, ctx)

    # A key created by a DIFFERENT user — the guard must reject it.
    {:ok, other_user} =
      Accounts.create_user(%{email: "other-owner-#{unique}@example.com", name: "Other"})

    {:ok, _} = Accounts.add_user_to_workspace(other_user, ctx)

    {:ok, foreign_key} =
      Accounts.create_api_key(%{
        name: "Foreign key",
        workspace_ids: [{ctx.id, "read"}],
        created_by_user_id: other_user.id
      })

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "plain-user-#{unique}@example.com")
      |> Plug.Conn.put_session(:workspace_slug, "personal")

    {:ok, view, _html} = live(conn, ~p"/settings/agents")

    # The foreign key never appears in the non-owner's list (list_api_keys
    # scopes by user) — so forge the event directly with its id, exactly like
    # a tampered DOM would. owned_api_key must reject it: flash error, NO
    # clipboard event.
    html = render_click(view, "copy_api_key_prefix", %{"id" => foreign_key.id})

    assert html =~ t("No autorizado.")
  end

  # ── Actors tab ──────────────────────────────────────────────────────────────

  describe "actors tab" do
    test "renders the actors tab with the create form and existing actors", %{conn: conn} do
      {:ok, _actor} = Dran.Actors.create_actor(%{name: "visible-actor", kind: "agent"})

      {:ok, view, html} = live(conn, ~p"/settings/agents")

      assert html =~ t("Agents")
      assert html =~ ~s(id="create-actor-form")
      assert html =~ "visible-actor"
      # solo agentes gestionables: no hay select de kind ni badge User
      refute html =~ ~s(field="actor[kind]")
      refute html =~ t("User")
      # System actors are never listed
      refute html =~ ~s(>system<)

      # The tab is reachable by patching from the api_keys tab
      html = view |> element("a", t("Agents")) |> render_click()
      assert html =~ t("Existing agents")
    end

    test "creating an actor with kind agent persists it and refreshes the list", %{conn: conn} do
      unique = System.unique_integer([:positive])
      name = "agent-#{unique}"

      {:ok, view, _html} = live(conn, ~p"/settings/agents")

      html =
        view
        |> form("#create-actor-form", %{
          "actor" => %{
            "name" => name,
            "display_name" => "Test Agent #{unique}",
            "host" => "ci-runner"
          }
        })
        |> render_submit()

      assert html =~ t("Agent created")
      assert html =~ name

      actor = Dran.Actors.get_actor_by_name(name)
      assert actor
      assert actor.kind == "agent"
      assert actor.display_name == "Test Agent #{unique}"
      assert actor.host == "ci-runner"
    end

    test "creating an actor with kind system is rejected with an error", %{conn: conn} do
      unique = System.unique_integer([:positive])
      name = "evil-system-#{unique}"

      {:ok, view, _html} = live(conn, ~p"/settings/agents")

      # kind is server-forced to agent: a tampered submit cannot create a
      # system actor — the row is created as an agent, never as system
      html =
        render_submit(view, "create_actor", %{
          "actor" => %{"name" => name, "kind" => "system"}
        })

      assert html =~ t("Agent created")
      actor = Dran.Actors.get_actor_by_name(name)
      assert actor && actor.kind == "agent"
    end

    test "editing an actor updates display_name and host only", %{conn: conn} do
      {:ok, actor} =
        Dran.Actors.create_actor(%{
          name: "editable-#{System.unique_integer([:positive])}",
          kind: "agent"
        })

      {:ok, view, _html} = live(conn, ~p"/settings/agents")

      _ = view |> element("#actor-#{actor.id} button[phx-click='edit_actor']") |> render_click()
      assert has_element?(view, "#edit-actor-modal")

      html =
        view
        |> form("#edit-actor-form", %{
          "actor" => %{"display_name" => "Renamed", "host" => "laptop"}
        })
        |> render_submit()

      assert html =~ t("Agent updated")

      reloaded = Dran.Actors.get_actor_by_name(actor.name)
      assert reloaded.display_name == "Renamed"
      assert reloaded.host == "laptop"
      assert reloaded.kind == "agent"
    end

    test "deleting an actor with API keys is blocked with a flash error", %{conn: conn} do
      unique = System.unique_integer([:positive])

      {:ok, ctx} =
        Knowledge.create_workspace(%{name: "ActorDel #{unique}", slug: "actor-del-#{unique}"})

      {:ok, actor} = Dran.Actors.create_actor(%{name: "keyed-#{unique}", kind: "agent"})

      user = Accounts.get_user_by_email("test_user")

      {:ok, _key} =
        Accounts.create_api_key(%{
          name: "keyed-key-#{unique}",
          workspace_ids: [{ctx.id, "read"}],
          created_by_user_id: user.id,
          actor_id: actor.id
        })

      {:ok, view, _html} = live(conn, ~p"/settings/agents")

      # Inline confirmation shows the attribution impact (0 pages/tasks/memories)
      html =
        view
        |> element("#actor-#{actor.id} button[phx-click='confirm_delete_actor']")
        |> render_click()

      assert html =~ t("Delete this actor?")
      assert html =~ "0"

      # The actual delete is refused: the actor still has API keys
      html = view |> element("button[phx-click='delete_actor']") |> render_click()

      assert html =~
               t("This actor still has API keys — revoke or delete them first")

      assert Dran.Actors.get_actor_by_name(actor.name)
    end
  end

  # Tests L104, L128 → /admin/users
  describe "google open signup toggle" do
    setup do
      Application.put_env(:dran, :google_oauth,
        client_id: "test-client",
        client_secret: "test-secret",
        redirect_uri: "http://localhost/auth/google/callback"
      )

      on_exit(fn ->
        Application.delete_env(:dran, :google_oauth)
        Dran.Repo.delete_all(from s in "settings", where: s.key == "wiki_google_open_signup")
      end)

      :ok
    end

    test "toggling persists the setting and re-renders the checkbox", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      toggle = "input[phx-click='toggle_wiki_google_signup']"

      refute Dran.Settings.get("wiki_google_open_signup")
      refute has_element?(view, "#{toggle}[checked]")

      _ = view |> element(toggle) |> render_click()

      assert Dran.Settings.get("wiki_google_open_signup") == true
      assert has_element?(view, "#{toggle}[checked]")

      _ = view |> element(toggle) |> render_click()

      refute Dran.Settings.get("wiki_google_open_signup")
      refute has_element?(view, "#{toggle}[checked]")
    end
  end

  # Test L199 → /admin (tabs change)
  test "admin page is organized as a landing with links to all sections", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin")

    # Navigation links to every admin section
    for tab_path <- ~w(/admin/users /admin/workspaces /admin/models /admin/system /admin/jobs) do
      assert html =~ tab_path
    end

    # Landing shows the admin title and intro
    assert html =~ t("Admin")

    # Automation settings are NOT on the landing (lives in /:ws/settings)
    refute html =~ "worker_max_pages"
  end

  # Tests L148, L176, L215 → /:ws/settings (reescribir a per-ws)
  describe "automation (brain tuning) per-workspace" do
    setup do
      # Create a workspace for automation settings tests
      unique = System.unique_integer([:positive])

      {:ok, ws} =
        Knowledge.create_workspace(%{
          name: "Brain Tuning #{unique}",
          slug: "brain-tuning-#{unique}",
          # The settings form only renders when all required features are on
          enabled_features: %{feature_goals: true}
        })

      # Add the test user to the workspace as owner
      user = Accounts.get_user_by_email("test_user")
      Accounts.add_user_to_workspace(user, ws)

      {:ok, ws: ws}
    end

    test "renders the automation form with default values", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")

      # Navigate to the Automation tab
      html =
        view
        |> element("button[phx-click='select_tab'][phx-value-tab='brain_tuning']")
        |> render_click()

      # Section heading (localized)
      assert html =~ t("Automation")

      # Primary fields visible
      for name <- ~w(worker_max_pages) do
        assert html =~ name
      end

      # Advanced thresholds tucked behind the details toggle
      assert html =~ "Avanzado"

      for name <- ~w(semantic_threshold_short semantic_threshold_mid semantic_threshold_long) do
        assert html =~ name
      end

      # Removed knobs are gone from the form
      refute html =~ "worker_max_sources"

      # Default values come from Workspace.get_tuning/2
      assert html =~ to_string(Dran.Workspace.get_tuning(ws, :semantic_threshold_short))
      assert html =~ to_string(Dran.Workspace.get_tuning(ws, :worker_max_pages))

      # Summary language select renders with the auto default
      assert has_element?(
               view,
               "#workspace-settings-form select[name='workspace[summary_language]']"
             )

      assert html =~ t("Summary language")

      assert html =~ t("Save")
    end

    test "saving the form persists values and shows a flash", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")

      # Navigate to the Automation tab
      _ =
        view
        |> element("button[phx-click='select_tab'][phx-value-tab='brain_tuning']")
        |> render_click()

      html =
        view
        |> form("#workspace-settings-form", %{
          "workspace" => %{
            "semantic_threshold_short" => "0.10",
            "semantic_threshold_mid" => "0.25",
            "semantic_threshold_long" => "0.30",
            "worker_max_pages" => "42",
            "summary_language" => "en"
          }
        })
        |> render_submit()

      # Success flash (localized)
      assert html =~ t("Settings saved")

      # The new values are persisted and readable via Workspace.get_tuning/2
      reloaded = Knowledge.get_workspace!(ws.id)
      assert Dran.Workspace.get_tuning(reloaded, :worker_max_pages) == 42
      assert Dran.Workspace.get_tuning(reloaded, :semantic_threshold_short) == 0.10

      # The language pin is persisted as-is
      assert reloaded.summary_language == "en"
    end

    test "the brain tuning form still renders the worker_max_pages input", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")

      # Navigate to the Automation tab
      html =
        view
        |> element("button[phx-click='select_tab'][phx-value-tab='brain_tuning']")
        |> render_click()

      assert html =~ "worker_max_pages"
      assert html =~ t("Max pages per run")
    end
  end

  # Tests L222, L229, L236 → /admin/system
  test "the Sistema header exists with its read-only caption", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/system")

    assert html =~ t("Sistema")
    assert html =~ t("Read-only — loaded from environment variables at startup.")
  end

  test "inference test button is present in the Inference API section", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/system")

    assert html =~ ~s(phx-click="test_inference")
    assert html =~ t("Probar conexión")
  end

  test "clicking the test button shows the testing state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/system")

    html = render_click(view, "test_inference")
    # The button immediately switches to "Probando..." state
    assert html =~ t("Probando...")
    # The button is disabled while testing
    assert html =~ "disabled"
  end

  # Test L246 → /admin/models
  test "models tab renders the selects with a per-model test button", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/models")

    assert html =~ ~s(id="models-form")

    for purpose <- ~w(model_chat model_embedding) do
      assert html =~ ~s(id="models_#{purpose}")
      assert html =~ ~s(id="test_model_#{purpose}")
      assert html =~ "data-model-key=\"#{purpose}\""
    end

    assert html =~ t("Probar")
  end

  # Tests L283, L301, L314, L334, L342 → /admin/jobs
  describe "jobs panel (brain tab)" do
    import Ecto.Query

    alias Dran.Jobs

    setup do
      # The panel reads the global "disabled_jobs" setting and the run reports
      # of the shared default context — start from a clean slate and leave none
      # behind (mirrors Dran.JobsTest's defensive cleanup).
      context =
        Dran.Knowledge.get_workspace_by_slug("personal") ||
          elem(Dran.Knowledge.create_workspace(%{name: "Personal", slug: "personal"}), 1)

      clear_disabled_jobs!()

      on_exit(fn ->
        # The OnExitHandler process owns no sandbox connection — check one out
        # or the delete_all below dies with an OwnershipError and fails the test.
        Ecto.Adapters.SQL.Sandbox.checkout(Dran.Repo)

        clear_disabled_jobs!()
        delete_job_reports!(context.id)
      end)

      :ok
    end

    test "renders the 6 registered jobs with toggles and run buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/jobs")

      assert html =~ t("Jobs programados")
      assert length(Jobs.list()) == 7

      for job <- Jobs.list() do
        assert html =~ ~s(id="job-row-#{job.key}")
        assert html =~ job.label
        assert html =~ ~s(id="job-toggle-#{job.key}")
        assert html =~ ~s(id="job-run-#{job.key}")
      end

      # No runs yet — gray "Nunca" badge and an enabled "Correr ahora" per job
      assert html =~ t("Nunca")
      assert html =~ t("Correr ahora")
    end

    test "toggle_job persists the enabled state and re-renders it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/jobs")
      assert Jobs.enabled?(:curator_daily)

      _ = view |> element("#job-toggle-curator_daily") |> render_click()
      refute Jobs.enabled?(:curator_daily)
      refute has_element?(view, "#job-toggle-curator_daily[checked]")

      _ = view |> element("#job-toggle-curator_daily") |> render_click()
      assert Jobs.enabled?(:curator_daily)
      assert has_element?(view, "#job-toggle-curator_daily[checked]")
    end

    test "run_job marks only that job as running, then flashes on completion", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/jobs")

      html = view |> element("#job-run-pagerank_nightly") |> render_click()

      # The Task's {:job_run_done, ...} message is handled after this reply, so
      # the returned HTML deterministically shows the running state — and only
      # for the clicked job.
      assert html =~ t("Corriendo…")
      assert html =~ ~r/<button(?=[^>]*\bdisabled\b)(?=[^>]*id="job-run-pagerank_nightly")/
      refute html =~ ~r/<button(?=[^>]*\bdisabled\b)(?=[^>]*id="job-run-curator_daily")/

      # Completion clears the running state, flashes and refreshes the list.
      # (The Task → run report wiring for the real job is covered in Dran.JobsTest.)
      send(view.pid, {:job_run_done, :pagerank_nightly, {:ok, %{}}})
      html = render(view)
      assert html =~ "Job completado: PageRank"
      refute html =~ t("Corriendo…")
    end

    test "job_run_done with an error result flashes the failure", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/jobs")

      send(view.pid, {:job_run_done, :curator_daily, {:error, :boom}})

      assert render(view) =~ "Job falló: Curator"
    end

    test "shows the last run with badge, relative time, duration and report link", %{conn: conn} do
      # Cheap real job (the same one Dran.JobsTest runs) — writes a run report.
      {:ok, report} = Jobs.run_now(:pagerank_nightly)

      {:ok, _view, html} = live(conn, ~p"/admin/jobs")

      # Green ok badge, relative time linking to the report, compact duration
      assert html =~ "badge-success"
      assert html =~ ~s(href="/reports/#{report.slug}")
      assert html =~ t("just now")
      assert html =~ ~r/\d+(\.\d+)? (ms|s)/
    end

    defp clear_disabled_jobs! do
      Dran.Repo.delete_all(from s in "settings", where: s.key == "disabled_jobs")
    end

    defp delete_job_reports!(workspace_id) do
      keys = Enum.map(Jobs.list_keys(), &Atom.to_string/1)

      Dran.Repo.delete_all(
        from p in Dran.Knowledge.Page,
          where: p.workspace_id == ^workspace_id and p.page_type == "report",
          where: fragment("?->>'job_key'", p.meta) in ^keys
      )
    end
  end
end
