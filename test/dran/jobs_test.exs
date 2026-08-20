defmodule Dran.JobsTest.FakeJob do
  @moduledoc false
  # Test MFA targets for Dran.Jobs.execute/3 (passed via the mfa override).

  def ok, do: {:ok, %{ran: true}}

  def ok_session do
    {:ok, %Dran.Agent.Session{id: Ecto.UUID.generate(), status: "running"}}
  end

  def error_tuple, do: {:error, :boom}

  def raise!, do: raise("job exploded")

  def exit!, do: exit(:killed)
end

defmodule Dran.JobsTest do
  # Dran.Jobs is the control plane for scheduled jobs: registry, runtime
  # toggles (Settings "disabled_jobs"), timed execution with a `report` page
  # per run, keep-20 archive retention, and list/0 with last_run.
  #
  # async: false — toggles are global settings rows and the jobs write to
  # the shared "personal" default context.
  use Dran.DataCase, async: false

  alias Dran.{Brain, Jobs, Repo}
  alias Dran.Brain.Report
  alias Dran.JobsTest.FakeJob

  @expected_keys [
    :curator_daily,
    :pagerank_nightly,
    :community_summaries_nightly,
    :graph_maintenance_nightly,
    :link_gardener_weekly
  ]

  setup do
    context = ensure_default_context!()
    clear_disabled_jobs!()

    on_exit(fn ->
      clear_disabled_jobs!()
      delete_job_reports!(context.id)
    end)

    {:ok, context: context}
  end

  # ── Registry ──────────────────────────────────────────────────────────────

  describe "registry" do
    test "lists the 5 known jobs in order" do
      assert Jobs.list_keys() == @expected_keys
    end

    test "get/1 returns the job definition with its MFA" do
      assert %{
               key: :curator_daily,
               label: "Curator",
               mfa: {Dran.Agent.Curator, :run_scheduled, []}
             } =
               Jobs.get(:curator_daily)

      assert %{mfa: {Dran.Graph, :refresh_all_scheduled, []}} = Jobs.get(:pagerank_nightly)

      assert %{mfa: {Dran.Graph.CommunitySummaries, :generate_all_scheduled, []}} =
               Jobs.get(:community_summaries_nightly)

      assert %{mfa: {Dran.Graph.Maintenance, :sweep_scheduled, []}} =
               Jobs.get(:graph_maintenance_nightly)

      assert %{mfa: {Dran.Agent.LinkGardener, :run_scheduled, []}} =
               Jobs.get(:link_gardener_weekly)

      assert Jobs.get(:nonexistent) == nil
    end
  end

  # ── Toggles ───────────────────────────────────────────────────────────────

  describe "toggles" do
    test "jobs are enabled by default" do
      assert Jobs.enabled?(:curator_daily)
      assert Jobs.disabled_jobs() == []
    end

    test "set_enabled/2 disables and re-enables idempotently" do
      assert :ok = Jobs.set_enabled(:curator_daily, false)
      refute Jobs.enabled?(:curator_daily)
      assert Jobs.disabled_jobs() == ["curator_daily"]

      # Idempotent: disabling twice keeps a single entry
      assert :ok = Jobs.set_enabled(:curator_daily, false)
      assert Jobs.disabled_jobs() == ["curator_daily"]

      assert :ok = Jobs.set_enabled(:curator_daily, true)
      assert Jobs.enabled?(:curator_daily)
      assert Jobs.disabled_jobs() == []

      # Enabling an already-enabled job is a no-op
      assert :ok = Jobs.set_enabled(:curator_daily, true)
      assert Jobs.disabled_jobs() == []
    end

    test "run_scheduled/1 skips a disabled job and writes no report", %{context: ctx} do
      Jobs.set_enabled(:curator_daily, false)

      assert Jobs.run_scheduled(:curator_daily) == :skipped
      assert count_job_reports(ctx.id, "curator_daily") == 0
    end

    test "execute with trigger \"manual\" runs even when the job is disabled", %{context: ctx} do
      Jobs.set_enabled(:curator_daily, false)

      assert {:ok, report} = Jobs.execute(:curator_daily, "manual", {FakeJob, :ok, []})
      assert report.meta["trigger"] == "manual"
      assert count_job_reports(ctx.id, "curator_daily") == 1
    end
  end

  # ── Execution + run reports ───────────────────────────────────────────────

  describe "execute/3" do
    test "writes an ok report for a successful run", %{context: ctx} do
      assert {:ok, report} = Jobs.execute(:curator_daily, "manual", {FakeJob, :ok, []})

      assert report.workspace_id == ctx.id
      assert report.report_type == "log"
      assert report.title =~ ~r/^Curator — \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC$/
      assert report.slug =~ ~r/^curator_daily-\d+$/

      assert report.meta["kind"] == "log"
      assert report.meta["job_key"] == "curator_daily"
      assert report.meta["status"] == "ok"
      assert report.meta["trigger"] == "manual"
      assert is_integer(report.meta["duration_ms"]) and report.meta["duration_ms"] >= 0
      assert is_binary(report.meta["summary"])

      assert report.body =~ "**Status:** ok"
      assert report.body =~ "**Trigger:** manual"
      assert report.body =~ "**Duration:**"
    end

    test "reports {:error, _} results as status error without raising" do
      assert {:error, report} =
               Jobs.execute(:pagerank_nightly, "scheduled", {FakeJob, :error_tuple, []})

      assert report.meta["status"] == "error"
      assert report.meta["trigger"] == "scheduled"
      assert report.body =~ ":boom"
    end

    test "catches exceptions and reports status error without raising" do
      assert {:error, report} = Jobs.execute(:curator_daily, "manual", {FakeJob, :raise!, []})

      assert report.meta["status"] == "error"
      assert report.meta["summary"] =~ "job exploded"
      assert report.body =~ "job exploded"
    end

    test "catches exits and reports status error without raising" do
      assert {:error, report} = Jobs.execute(:curator_daily, "manual", {FakeJob, :exit!, []})
      assert report.meta["status"] == "error"
    end

    test "session results include the session id in body and summary" do
      assert {:ok, report} = Jobs.execute(:curator_daily, "scheduled", {FakeJob, :ok_session, []})

      assert report.meta["summary"] =~ ~r/^Agent session .+ started$/
      assert report.body =~ "Agent session"
      assert report.body =~ "status: **running**"
    end

    test "raises ArgumentError for unknown job keys" do
      assert_raise ArgumentError, ~r/unknown job/, fn ->
        Jobs.execute(:nope, "manual")
      end
    end

    test "reports land in the default context (not other contexts)", %{context: ctx} do
      {:ok, other} = Brain.create_workspace(%{name: "Other", slug: "other"})

      assert {:ok, report} = Jobs.execute(:curator_daily, "manual", {FakeJob, :ok, []})
      assert report.workspace_id == ctx.id
      refute report.workspace_id == other.id
    end
  end

  # ── Scheduled/manual entry points (real MFA, cheap job) ──────────────────

  describe "run_scheduled/1 and run_now/1 (real pagerank job)" do
    test "run_scheduled executes an enabled job and writes a scheduled report", %{context: ctx} do
      assert {:ok, report} = Jobs.run_scheduled(:pagerank_nightly)

      assert report.meta["status"] == "ok"
      assert report.meta["trigger"] == "scheduled"
      assert report.meta["job_key"] == "pagerank_nightly"
      assert report.report_type == "log"
      assert count_job_reports(ctx.id, "pagerank_nightly") == 1
    end

    test "run_now ignores the disabled toggle", %{context: ctx} do
      Jobs.set_enabled(:pagerank_nightly, false)

      assert {:ok, report} = Jobs.run_now(:pagerank_nightly)
      assert report.meta["trigger"] == "manual"
      assert count_job_reports(ctx.id, "pagerank_nightly") == 1
    end
  end

  # ── Retention ─────────────────────────────────────────────────────────────

  describe "prune_reports/2" do
    test "keeps the newest 20 reports and archives the rest", %{context: ctx} do
      insert_reports!(ctx.id, "pagerank_nightly", 25)

      assert :ok = Jobs.prune_reports(:pagerank_nightly, keep: 20)

      active = job_reports(ctx.id, "pagerank_nightly", archived: false)
      archived = job_reports(ctx.id, "pagerank_nightly", archived: true)

      assert length(active) == 20
      assert length(archived) == 5

      # The 5 oldest (runs 1..5) are the archived ones
      archived_slugs = Enum.map(archived, & &1.slug)

      for i <- 1..5 do
        assert "pagerank_nightly-#{i}" in archived_slugs
      end
    end

    test "does nothing when at or under the keep limit", %{context: ctx} do
      insert_reports!(ctx.id, "pagerank_nightly", 20)

      assert :ok = Jobs.prune_reports(:pagerank_nightly, keep: 20)

      assert length(job_reports(ctx.id, "pagerank_nightly", archived: false)) == 20
      assert job_reports(ctx.id, "pagerank_nightly", archived: true) == []
    end

    test "execute prunes automatically after writing its report", %{context: ctx} do
      insert_reports!(ctx.id, "pagerank_nightly", 20)

      assert {:ok, _report} = Jobs.execute(:pagerank_nightly, "manual", {FakeJob, :ok, []})

      active = job_reports(ctx.id, "pagerank_nightly", archived: false)
      archived = job_reports(ctx.id, "pagerank_nightly", archived: true)

      # 21 total: newest 20 active, the oldest one archived
      assert length(active) == 20
      assert [%{slug: "pagerank_nightly-1"}] = archived
    end
  end

  # ── list/0 ────────────────────────────────────────────────────────────────

  describe "list/0" do
    test "returns every job with schedule, enabled? and last_run", %{context: _ctx} do
      {:ok, report} = Jobs.execute(:curator_daily, "manual", {FakeJob, :ok, []})
      Jobs.set_enabled(:link_gardener_weekly, false)

      list = Jobs.list()
      assert Enum.map(list, & &1.key) == @expected_keys

      curator = Enum.find(list, &(&1.key == :curator_daily))
      assert curator.label == "Curator"
      assert curator.enabled? == true
      # Test env config sets `jobs: []`, so no cron schedule is available
      assert curator.schedule == "—"
      assert curator.last_run.slug == report.slug
      assert curator.last_run.status == "ok"
      assert curator.last_run.trigger == "manual"
      assert is_integer(curator.last_run.duration_ms)
      assert %DateTime{} = curator.last_run.at

      gardener = Enum.find(list, &(&1.key == :link_gardener_weekly))
      assert gardener.enabled? == false
      assert gardener.last_run == nil
    end

    test "last_run reflects the most recent report only", %{context: _ctx} do
      {:ok, first} = Jobs.execute(:curator_daily, "scheduled", {FakeJob, :ok, []})

      # Backdate the first report so inserted_at ordering is deterministic
      # (no sleeps; inserted_at is truncated to seconds).
      Repo.update!(
        Ecto.Changeset.change(first, inserted_at: DateTime.add(first.inserted_at, -10, :second))
      )

      {:error, second} = Jobs.execute(:curator_daily, "manual", {FakeJob, :error_tuple, []})

      curator = Enum.find(Jobs.list(), &(&1.key == :curator_daily))
      assert curator.last_run.slug == second.slug
      assert curator.last_run.status == "error"
      assert curator.last_run.trigger == "manual"
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp ensure_default_context! do
    Brain.get_workspace_by_slug("personal") ||
      elem(Brain.create_workspace(%{name: "Personal", slug: "personal"}), 1)
  end

  defp clear_disabled_jobs! do
    Repo.delete_all(from s in "settings", where: s.key == "disabled_jobs")
  end

  # Defensive: Jobs.execute/3 always writes run reports to the shared default
  # context, and this suite inserts report fixtures there too. The sandbox
  # rolls every test back, but if that ever changes (or a test run dies
  # mid-transaction), these reports must not leak into other suites that
  # assert exact page counts on the same context.
  defp delete_job_reports!(workspace_id) do
    keys = Enum.map(@expected_keys, &Atom.to_string/1)

    Repo.delete_all(
      from r in Report,
        where: r.workspace_id == ^workspace_id,
        where: fragment("?->>'job_key'", r.meta) in ^keys
    )
  end

  defp insert_reports!(workspace_id, job_key, count) do
    base = DateTime.utc_now() |> DateTime.add(-count, :second) |> DateTime.truncate(:second)

    for i <- 1..count do
      at = DateTime.add(base, i, :second)

      %Report{
        workspace_id: workspace_id,
        title: "Run #{i}",
        slug: "#{job_key}-#{i}",
        body: "report #{i}",
        report_type: "log",
        meta: %{"kind" => "log", "job_key" => job_key, "status" => "ok"},
        inserted_at: at,
        updated_at: at
      }
      |> Repo.insert!()
    end

    :ok
  end

  defp job_reports(workspace_id, job_key, archived: archived?) do
    Repo.all(
      from r in Report,
        where:
          r.workspace_id == ^workspace_id and
            r.archived == ^archived?,
        where: fragment("?->>'job_key' = ?", r.meta, ^job_key),
        order_by: [desc: r.inserted_at]
    )
  end

  defp count_job_reports(workspace_id, job_key) do
    Repo.one(
      from r in Report,
        where: r.workspace_id == ^workspace_id,
        where: fragment("?->>'job_key' = ?", r.meta, ^job_key),
        select: count(r.id)
    )
  end
end
