defmodule Dran.Jobs do
  @moduledoc """
  Registry and control plane for Dran's scheduled jobs (Quantum crons).

  Every recurring task the brain runs (curator, pagerank, cluster
  summaries, graph maintenance, link gardener) is declared once in the
  `@jobs` registry below. The Quantum scheduler in `config/config.exs`
  does NOT call the job modules directly — it calls
  `Dran.Jobs.run_scheduled/1`, which:

    * Skips disabled jobs (returns `:skipped`, writes nothing).
    * Executes enabled jobs, times them, and writes ONE report row
      (in the `reports` table, `report_type: "log"`) per run with the status,
      duration, trigger and a compact markdown body.
    * Prunes old run reports for the job, keeping the newest 20
      (older ones are archived, never deleted).

  ## Toggles

  Jobs can be disabled at runtime without a deploy. The toggle state lives
  in `Dran.Settings` under the key `"disabled_jobs"` (a list of job-key
  strings). Manual runs (`run_now/1`) ALWAYS execute — the toggle only
  affects scheduled runs.

  The Settings → Brain "Jobs programados" panel (`DranWeb.SettingsLive`)
  drives `set_enabled/2` and `run_now/1` from the UI, listing each job's
  schedule and last run (status, duration, link to its report page).

  ## Adding a new job

  1. Add an entry to `@jobs` here (`key`, `label`, `mfa`, `description`).
  2. Add the Quantum entry in `config/config.exs`:
     `my_job: [schedule: "0 4 * * *", task: {Dran.Jobs, :run_scheduled, [:my_job]}]`
     (inside the existing `if config_env() != :test` guard).

  Reports are second-citizen entities (see `Dran.Report`): no graph,
  no journey, no embeddings — they cost zero inference. They are viewable
  at `/reports/:slug`.
  """

  import Ecto.Query

  alias Dran.{Knowledge, Repo, Reports, Settings}
  alias Dran.Agent.Session
  alias Dran.Report

  require Logger

  @disabled_jobs_key "disabled_jobs"
  @reports_keep 20

  @jobs [
    %{
      key: :curator_daily,
      label: "Curator",
      mfa: {Dran.Agent.Curator, :run_scheduled, []},
      description:
        "Daily janitor pass: finds embedding-duplicate pages, flags contested ones " <>
          "and writes a curator report."
    },
    %{
      key: :pagerank_nightly,
      label: "PageRank",
      mfa: {Dran.Graph, :refresh_all_scheduled, []},
      description:
        "Nightly graph recompute: PageRank scores, clusters and related graph " <>
          "materializations for the default context."
    },
    %{
      key: :cluster_summaries_nightly,
      label: "Cluster summaries",
      mfa: {Dran.Graph.ClusterSummaries, :generate_all_scheduled, []},
      description: "Nightly LLM summaries for every graph cluster in the default context."
    },
    %{
      key: :graph_maintenance_nightly,
      label: "Graph maintenance",
      mfa: {Dran.Graph.Maintenance, :sweep_scheduled, []},
      description:
        "Nightly hygiene sweep: prunes stale low-weight/derived relations that no " <>
          "longer reflect the graph."
    },
    %{
      key: :link_gardener_weekly,
      label: "Link gardener",
      mfa: {Dran.Agent.LinkGardener, :run_scheduled, []},
      description:
        "Weekly gardener pass: reviews relation suggestions and proposes new links " <>
          "between pages."
    }
  ]

  # ── Registry ──────────────────────────────────────────────────────────────

  @doc "Ordered list of registered job keys."
  @spec list_keys() :: [atom()]
  def list_keys, do: Enum.map(@jobs, & &1.key)

  @doc "Get a job definition by key, or nil if unknown."
  @spec get(atom()) :: map() | nil
  def get(key), do: Enum.find(@jobs, &(&1.key == key))

  @doc """
  Full listing for UI/ops: every job with its schedule (from app config),
  enabled state, and last run (from the newest run report).
  """
  @spec list() :: [map()]
  def list do
    schedules = configured_schedules()
    last_runs = last_runs_by_job()

    Enum.map(@jobs, fn job ->
      %{
        key: job.key,
        label: job.label,
        description: job.description,
        schedule: Map.get(schedules, job.key, "—"),
        enabled?: enabled?(job.key),
        last_run: Map.get(last_runs, Atom.to_string(job.key))
      }
    end)
  end

  # ── Toggles ─────────────────────────────────────────────────────────────

  @doc "List of disabled job keys (strings), as persisted in settings."
  @spec disabled_jobs() :: [String.t()]
  def disabled_jobs do
    case Settings.get(@disabled_jobs_key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc "True when the job is enabled (not present in the disabled list)."
  @spec enabled?(atom()) :: boolean()
  def enabled?(key), do: Atom.to_string(key) not in disabled_jobs()

  @doc """
  Enable or disable a job (idempotent). Persists the disabled-jobs list in
  `Dran.Settings`. Only affects scheduled runs — `run_now/1` always runs.
  """
  @spec set_enabled(atom(), boolean()) :: :ok
  def set_enabled(key, enabled?) when is_boolean(enabled?) do
    key_str = Atom.to_string(key)
    disabled = disabled_jobs()

    updated =
      if enabled? do
        List.delete(disabled, key_str)
      else
        Enum.uniq([key_str | disabled])
      end

    Settings.put(@disabled_jobs_key, updated)
    :ok
  end

  # ── Running ───────────────────────────────────────────────────────────────

  @doc """
  Entry point called by the Quantum scheduler. Returns `:skipped` (writing
  nothing) when the job is disabled; otherwise executes and reports.
  """
  @spec run_scheduled(atom()) :: :skipped | {:ok, Page.t()} | {:error, term()}
  def run_scheduled(key) do
    if enabled?(key) do
      execute(key, "scheduled")
    else
      Logger.info("Dran.Jobs: #{key} is disabled, skipping scheduled run")
      :skipped
    end
  end

  @doc """
  Run a job right now (manual trigger). ALWAYS executes, ignoring the
  enabled/disabled toggle.
  """
  @spec run_now(atom()) :: {:ok, Page.t()} | {:error, term()}
  def run_now(key), do: execute(key, "manual")

  @doc """
  Execute a job, time it, and write a run report page.

  Never raises for job failures: exceptions/exits/throws from the job MFA
  are caught and recorded as a report with `status: "error"`. Returns
  `{:ok, report}` when the job succeeded, `{:error, report}` when it
  failed, or `{:error, reason}` when the report itself could not be
  written (e.g. no default context).

  The optional third argument overrides the job's MFA — intended for tests.
  """
  @spec execute(atom(), String.t(), {module(), atom(), list()} | nil) ::
          {:ok, Page.t()} | {:error, term()}
  def execute(key, trigger, mfa \\ nil) when trigger in ["scheduled", "manual"] do
    job = get(key) || raise ArgumentError, "unknown job: #{inspect(key)}"
    {mod, fun, args} = mfa || job.mfa

    started = System.monotonic_time()

    {status, result_text, summary} =
      try do
        case apply(mod, fun, args) do
          {:error, reason} = result ->
            {"error", result_section(result), "Returned error: #{truncate_inspect(reason, 200)}"}

          result ->
            {"ok", result_section(result), ok_summary(result)}
        end
      rescue
        exception ->
          {"error", "**Exception:** `#{Exception.message(exception)}`",
           truncate_inspect(Exception.message(exception), 200)}
      catch
        kind, reason ->
          {"error", "**#{kind}:** `#{truncate_inspect(reason)}`",
           truncate_inspect("#{kind}: #{inspect(reason)}", 200)}
      end

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    report_result = write_report(job, trigger, status, duration_ms, result_text, summary)

    # Best-effort retention: prune AFTER writing so the newest report is
    # never archived. Failures here must not fail the run.
    safe_prune(job.key)

    case {status, report_result} do
      {_, {:error, reason}} ->
        Logger.error("Dran.Jobs: could not write run report for #{job.key}: #{inspect(reason)}")
        {:error, reason}

      {"ok", {:ok, report}} ->
        # Reload so meta comes back with string keys (jsonb round-trip),
        # matching what any later DB read would return.
        {:ok, Repo.get!(Report, report.id)}

      {"error", {:ok, report}} ->
        {:error, Repo.get!(Report, report.id)}
    end
  end

  # ── Retention ─────────────────────────────────────────────────────────────

  @doc """
  Archive run reports of a job beyond the newest `:keep` (default 20).
  Archives (`archived: true`), never deletes. Best-effort.
  """
  @spec prune_reports(atom(), keyword()) :: :ok
  def prune_reports(key, opts \\ []) do
    keep = Keyword.get(opts, :keep, @reports_keep)
    key_str = Atom.to_string(key)

    case default_context() do
      nil ->
        :ok

      context ->
        excess =
          Repo.all(
            from r in Report,
              where:
                r.workspace_id == ^context.id and
                  r.archived == false,
              where: fragment("?->>'job_key' = ?", r.meta, ^key_str),
              order_by: [desc: r.inserted_at],
              offset: ^keep
          )

        Enum.each(excess, fn report ->
          case Repo.update(Report.changeset(report, %{"archived" => true})) do
            {:ok, _} ->
              :ok

            {:error, changeset} ->
              Logger.warning(
                "Dran.Jobs: failed to archive old report #{report.slug}: #{inspect(changeset.errors)}"
              )
          end
        end)

        :ok
    end
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp default_context do
    Knowledge.get_workspace_by_slug(Dran.Auth.default_workspace_slug())
  end

  defp safe_prune(key) do
    prune_reports(key, keep: @reports_keep)
  rescue
    exception ->
      Logger.warning(
        "Dran.Jobs: report pruning failed for #{key}: #{Exception.message(exception)}"
      )

      :ok
  end

  defp write_report(job, trigger, status, duration_ms, result_text, summary) do
    case default_context() do
      nil ->
        {:error, :workspace_not_found}

      context ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        key_str = Atom.to_string(job.key)
        slug = "#{key_str}-#{DateTime.to_unix(now)}"

        attrs =
          report_attrs(
            job,
            context,
            now,
            slug,
            trigger,
            status,
            duration_ms,
            result_text,
            summary
          )

        case Reports.create_report(attrs) do
          # Two runs within the same second would collide on the slug —
          # retry once with a uniqueness suffix, keeping the canonical
          # "<key>-<unix_seconds>" format for the normal path.
          {:error, %Ecto.Changeset{} = changeset} ->
            if slug_taken?(changeset) do
              suffix = Integer.to_string(System.unique_integer([:positive]), 36)

              Reports.create_report(%{attrs | slug: "#{slug}-#{String.downcase(suffix)}"})
            else
              {:error, changeset}
            end

          other ->
            other
        end
    end
  end

  defp report_attrs(job, context, now, slug, trigger, status, duration_ms, result_text, summary) do
    key_str = Atom.to_string(job.key)

    %{
      workspace_id: context.id,
      title: "#{job.label} — #{Calendar.strftime(now, "%Y-%m-%d %H:%M")} UTC",
      slug: slug,
      body: report_body(status, trigger, duration_ms, result_text),
      report_type: "log",
      meta: %{
        kind: "log",
        job_key: key_str,
        status: status,
        duration_ms: duration_ms,
        trigger: trigger,
        summary: summary
      }
    }
  end

  # Page's only unique constraint is (workspace_id, slug); the error is
  # attached to the first field of the composite, so match on constraint type.
  defp slug_taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end)
  end

  defp report_body(status, trigger, duration_ms, result_text) do
    """
    **Status:** #{status}
    **Trigger:** #{trigger}
    **Duration:** #{duration_ms} ms

    #{result_text}
    """
  end

  defp result_section({:ok, %Session{} = session}) do
    "Agent session `#{session.id}` started (status: **#{session.status}**)."
  end

  defp result_section(result) do
    "**Result:** `#{truncate_inspect(result)}`"
  end

  defp ok_summary({:ok, %Session{} = session}), do: "Agent session #{session.id} started"
  defp ok_summary(_result), do: "Completed successfully"

  defp truncate_inspect(term, limit \\ 500) do
    text = if is_binary(term), do: term, else: inspect(term, limit: 20)

    if String.length(text) > limit do
      String.slice(text, 0, limit) <> "…"
    else
      text
    end
  end

  defp configured_schedules do
    :dran
    |> Application.get_env(Dran.Scheduler, [])
    |> Keyword.get(:jobs, [])
    |> Map.new(fn {key, opts} -> {key, Keyword.get(opts, :schedule, "—")} end)
  end

  # Latest run report per job (active reports only — pruned ones are
  # archived, and a job's newest report is never archived by pruning).
  defp last_runs_by_job do
    case default_context() do
      nil ->
        %{}

      context ->
        Repo.all(
          from r in Report,
            where: r.workspace_id == ^context.id and r.archived == false,
            where: not is_nil(fragment("?->>'job_key'", r.meta)),
            order_by: [desc: r.inserted_at],
            limit: 500,
            select: %{
              job_key: fragment("?->>'job_key'", r.meta),
              status: fragment("?->>'status'", r.meta),
              duration_ms: fragment("?->>'duration_ms'", r.meta),
              trigger: fragment("?->>'trigger'", r.meta),
              slug: r.slug,
              at: r.inserted_at
            }
        )
        |> Enum.uniq_by(& &1.job_key)
        |> Map.new(fn run ->
          {run.job_key,
           %{
             at: run.at,
             status: run.status,
             duration_ms: parse_int(run.duration_ms),
             trigger: run.trigger,
             slug: run.slug
           }}
        end)
    end
  end

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_int(value), do: value
end
