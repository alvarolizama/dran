defmodule Dran.SchedulerTest do
  use ExUnit.Case, async: true

  alias Dran.Scheduler

  describe "supervision tree" do
    test "Dran.Scheduler is a child of Dran.Supervisor" do
      children = Supervisor.which_children(Dran.Supervisor)

      child_ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)

      assert Scheduler in child_ids,
             "expected Dran.Scheduler to be supervised by Dran.Supervisor, " <>
               "got: #{inspect(child_ids)}"
    end

    test "Dran.Scheduler is running" do
      children = Supervisor.which_children(Dran.Supervisor)

      {_, pid, _, _} =
        Enum.find(children, fn {id, _, _, _} -> id == Scheduler end) ||
          flunk("Dran.Scheduler not found in supervisor children")

      assert is_pid(pid) and Process.alive?(pid)
    end
  end

  describe "scheduler config" do
    test "in test env jobs are disabled (empty list)" do
      # config.exs guards the jobs definition with `if config_env() != :test`,
      # and test.exs sets `jobs: []`. Either way, no scheduled jobs should be
      # present in the running test application.
      config = Application.get_env(:dran, Scheduler) || []
      jobs = Keyword.get(config, :jobs, [])

      assert jobs == [],
             "scheduler jobs must be disabled in test env (expected []), got: " <>
               "#{inspect(jobs)}"
    end

    test "production config (config.exs) declares the expected jobs" do
      # Read the source of config.exs so the assertion locks in the schedule
      # and task pairs independent of the test-env guard. All tasks route
      # through Dran.Jobs.run_scheduled/1 (job control plane: toggles + run
      # reports); the registry in Dran.Jobs holds the actual job MFAs.
      config_path = Path.join([File.cwd!(), "config", "config.exs"])
      source = File.read!(config_path)

      for {key, cron} <- [
            {:curator_daily, "0 6 * * *"},
            {:pagerank_nightly, "0 3 * * *"},
            {:cluster_summaries_nightly, "30 3 * * *"},
            {:graph_maintenance_nightly, "45 3 * * *"},
            {:link_gardener_weekly, "0 7 * * 0"}
          ] do
        assert source =~ "#{key}:"
        assert source =~ ~s(schedule: "#{cron}")
        assert source =~ ~s({Dran.Jobs, :run_scheduled, [:#{key}]})
      end
    end
  end
end
