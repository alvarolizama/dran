defmodule DranWeb.SettingsLiveTest do
  use DranWeb.ConnCase, async: false

  import Ecto.Query

  alias Dran.Accounts
  alias Dran.Settings

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

    {:ok, conn: conn}
  end

  test "the api keys tab renders the list and opens the create modal", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings/api_keys")

    # The tab renders the (empty) list of the current user's keys
    assert html =~ t("No API keys yet — create one with the button above.")
    refute html =~ ~s(id="create-api-key-form")

    # Opening the modal reveals the multi-workspace create form
    html = view |> element("button[phx-click='open_api_key_modal']") |> render_click()
    assert html =~ ~s(id="create-api-key-form")
  end

  test "creating an api key from the modal reveals the token once", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, ctx} =
      Dran.Knowledge.create_workspace(%{name: "Keys #{unique}", slug: "keys-#{unique}"})

    {:ok, view, _html} = live(conn, ~p"/settings/api_keys")

    view |> element("button[phx-click='open_api_key_modal']") |> render_click()

    html =
      view
      |> form("#create-api-key-form",
        api_key: %{
          "name" => "Hermes",
          "workspaces" => %{"#{ctx.id}" => "read"},
          "level" => %{"#{ctx.id}" => "write"}
        }
      )
      |> render_submit()

    # The one-time reveal card shows the full token + copy button
    assert html =~ ~s(id="revealed-api-key-card")
    assert html =~ ~s(id="copy-revealed-key-btn")

    # The key now appears in the list with masked prefix only
    assert html =~ "Hermes"
    assert html =~ "••••••••••••"
  end

  test "revoking a key from the list marks it revoked", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, ctx} =
      Dran.Knowledge.create_workspace(%{name: "Keys #{unique}", slug: "keys-#{unique}"})

    user = Accounts.get_user_by_email("test_user")

    {:ok, key} =
      Accounts.create_api_key(%{
        name: "Revocable",
        workspace_ids: [{ctx.id, "read"}],
        created_by_user_id: user.id
      })

    {:ok, view, _html} = live(conn, ~p"/settings/api_keys")

    html =
      view
      |> element("#api-key-#{key.id} button[phx-click='revoke_api_key']")
      |> render_click()

    assert html =~ t("Revoked")
    assert Accounts.valid_api_key?(key.token) == :error
  end

  test "users tab shows a default context selector per user", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/users")

    assert html =~ t("Default context")
    assert html =~ "default-context-select-"
  end

  describe "google open signup toggle" do
    setup do
      Application.put_env(:dran, :google_oauth,
        client_id: "test-client",
        client_secret: "test-secret",
        redirect_uri: "http://localhost/auth/google/callback",
        allowed_domains: []
      )

      on_exit(fn ->
        Application.delete_env(:dran, :google_oauth)
        Dran.Repo.delete_all(from s in "settings", where: s.key == "wiki_google_open_signup")
      end)

      :ok
    end

    test "toggling persists the setting and re-renders the checkbox", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/users")

      toggle = "input[phx-click='toggle_wiki_google_signup']"

      refute Settings.get("wiki_google_open_signup")
      refute has_element?(view, "#{toggle}[checked]")

      _ = view |> element(toggle) |> render_click()

      assert Settings.get("wiki_google_open_signup") == true
      assert has_element?(view, "#{toggle}[checked]")

      _ = view |> element(toggle) |> render_click()

      refute Settings.get("wiki_google_open_signup")
      refute has_element?(view, "#{toggle}[checked]")
    end
  end

  test "renders the brain tuning form with default values", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/brain")

    # Section heading (localized)
    assert html =~ t("Brain tuning")

    # Primary fields visible
    for name <- ~w(agent_max_pages) do
      assert html =~ name
    end

    # Advanced thresholds tucked behind the details toggle
    assert html =~ "Avanzado"

    for name <- ~w(semantic_threshold_short semantic_threshold_mid semantic_threshold_long) do
      assert html =~ name
    end

    # Removed knobs are gone from the form
    refute html =~ "agent_max_sources"

    # Default values come from Dran.Settings.defaults/0
    defaults = Settings.defaults()
    assert html =~ to_string(defaults["semantic_threshold_short"])
    assert html =~ to_string(defaults["agent_max_pages"])
    assert html =~ t("Save")
  end

  test "saving the form persists values and shows a flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/brain")

    html =
      view
      |> form("#brain-tuning-form", %{
        "settings" => %{
          "semantic_threshold_short" => "0.10",
          "semantic_threshold_mid" => "0.25",
          "semantic_threshold_long" => "0.30",
          "agent_max_pages" => "42"
        }
      })
      |> render_submit()

    # Success flash (localized)
    assert html =~ t("Settings saved")

    # The new values are persisted and readable via Settings.get/1
    assert Settings.get("agent_max_pages") == 42
    assert Settings.get("semantic_threshold_short") == 0.10
  end

  test "settings page is organized by tabs with users as default", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings")

    # Tab navigation present with all tabs
    for tab_path <-
          ~w(/settings/users /settings/workspaces /settings/brain /settings/models /settings/system /settings/danger) do
      assert html =~ tab_path
    end

    # Default tab is users — shows user management
    assert html =~ t("Add User")

    # Brain tuning is NOT on the default tab (lives in /settings/brain)
    refute html =~ "agent_max_pages"
  end

  test "the brain tuning form still renders the agent_max_pages input", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/brain")

    assert html =~ "agent_max_pages"
    assert html =~ t("Max pages per run")
  end

  test "the Entorno header exists with its read-only caption", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/system")

    assert html =~ t("Entorno")
    assert html =~ t("Read-only — loaded from environment variables at startup.")
  end

  test "inference test button is present in the Inference API section", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/system")

    assert html =~ "phx-click=\"test_inference\""
    assert html =~ t("Probar conexión")
  end

  test "clicking the test button shows the testing state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/system")

    html = render_click(view, "test_inference")
    # The button immediately switches to "Probando..." state
    assert html =~ t("Probando...")
    # The button is disabled while testing
    assert html =~ "disabled"
  end

  test "models tab renders the selects with a per-model test button", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/models")

    assert html =~ ~s(id="models-form")

    for purpose <- ~w(model_chat model_embedding model_rerank) do
      assert html =~ ~s(id="models_#{purpose}")
      assert html =~ ~s(id="test_model_#{purpose}")
      assert html =~ "data-model-key=\"#{purpose}\""
    end

    assert html =~ t("Probar")
  end

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
        clear_disabled_jobs!()
        delete_job_reports!(context.id)
      end)

      :ok
    end

    test "renders the 5 registered jobs with toggles and run buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/brain")

      assert html =~ t("Jobs programados")
      assert length(Jobs.list()) == 5

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
      {:ok, view, _html} = live(conn, ~p"/settings/brain")
      assert Jobs.enabled?(:curator_daily)

      _ = view |> element("#job-toggle-curator_daily") |> render_click()
      refute Jobs.enabled?(:curator_daily)
      refute has_element?(view, "#job-toggle-curator_daily[checked]")

      _ = view |> element("#job-toggle-curator_daily") |> render_click()
      assert Jobs.enabled?(:curator_daily)
      assert has_element?(view, "#job-toggle-curator_daily[checked]")
    end

    test "run_job marks only that job as running, then flashes on completion", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/brain")

      html = view |> element("#job-run-pagerank_nightly") |> render_click()

      # The Task's {:job_run_done, ...} message is handled after this reply, so
      # the returned HTML deterministically shows the running state — and only
      # for the clicked job.
      assert html =~ t("Corriendo…")
      assert html =~ ~r/<button(?=[^>]*\bdisabled\b)(?=[^>]*id="job-run-pagerank_nightly")[^>]*>/
      refute html =~ ~r/<button(?=[^>]*\bdisabled\b)(?=[^>]*id="job-run-curator_daily")[^>]*>/

      # Completion clears the running state, flashes and refreshes the list.
      # (The Task → run report wiring for the real job is covered in Dran.JobsTest.)
      send(view.pid, {:job_run_done, :pagerank_nightly, {:ok, %{}}})
      html = render(view)
      assert html =~ "Job completado: PageRank"
      refute html =~ t("Corriendo…")
    end

    test "job_run_done with an error result flashes the failure", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/brain")

      send(view.pid, {:job_run_done, :curator_daily, {:error, :boom}})

      assert render(view) =~ "Job falló: Curator"
    end

    test "shows the last run with badge, relative time, duration and report link", %{conn: conn} do
      # Cheap real job (the same one Dran.JobsTest runs) — writes a run report.
      {:ok, report} = Jobs.run_now(:pagerank_nightly)

      {:ok, _view, html} = live(conn, ~p"/settings/brain")

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
        from p in Dran.Page,
          where: p.workspace_id == ^workspace_id and p.page_type == "report",
          where: fragment("?->>'job_key'", p.meta) in ^keys
      )
    end
  end
end
