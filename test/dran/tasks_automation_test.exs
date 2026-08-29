defmodule Dran.TasksAutomationTest do
  use Dran.DataCase, async: false

  alias Dran.Tasks
  alias Dran.Tasks.Automation

  describe "handle_completion/1 (recurrence)" do
    test "clones a completed weekly task with next due date and copied links" do
      workspace = ensure_workspace!()

      {:ok, goal} =
        Dran.Goals.create_goal(%{
          "workspace_id" => workspace.id,
          "title" => "Fit",
          "slug" => "goal-fit"
        })

      {:ok, task} =
        Tasks.create_task(%{
          "workspace_id" => workspace.id,
          "title" => "Correr 3x",
          "slug" => "correr-3x",
          "status" => "in_progress",
          "due_date" => "2026-08-24",
          "recurrence" => "weekly"
        })

      Tasks.link_to_goal(task, goal)

      # Complete it → automation clones
      {:ok, clone} = Automation.handle_completion(%{task | status: "done"})

      assert clone.slug == "correr-3x-2"
      assert clone.status == "backlog"
      assert clone.recurrence == "weekly"
      assert to_string(clone.due_date) == "2026-08-31"
      assert clone.created_by == "automation:recurrence"

      # Goal links copied to the clone
      assert Tasks.list_linked_goals(clone) |> length() == 1
    end

    test "no-op for non-recurring tasks" do
      assert {:ok, :not_recurring} =
               Automation.handle_completion(%Dran.Task{recurrence: "none", status: "done"})
    end

    test "no-op for recurring task not in terminal status" do
      assert {:ok, :not_recurring} =
               Automation.handle_completion(%Dran.Task{
                 recurrence: "daily",
                 status: "in_progress"
               })
    end
  end

  describe "next_due_date/2" do
    test "daily adds one day" do
      assert Automation.next_due_date(~D[2026-08-26], "daily") == ~D[2026-08-27]
    end

    test "weekly adds seven days" do
      assert Automation.next_due_date(~D[2026-08-26], "weekly") == ~D[2026-09-02]
    end

    test "monthly clamps to month length (Jan 31 → Feb 28)" do
      assert Automation.next_due_date(~D[2026-01-31], "monthly") == ~D[2026-02-28]
    end

    test "monthly crosses year boundary (Dec 15 → Jan 15)" do
      assert Automation.next_due_date(~D[2026-12-15], "monthly") == ~D[2027-01-15]
    end
  end

  describe "move_task triggers recurrence" do
    test "moving a weekly task to done creates the clone via the context path" do
      workspace = ensure_workspace!()

      {:ok, task} =
        Tasks.create_task(%{
          "workspace_id" => workspace.id,
          "title" => "Repasar inbox",
          "recurrence" => "daily"
        })

      {:ok, _done} = Tasks.move_task(task, "done")

      clone = Tasks.get_task_by_slug("repasar-inbox-2", workspace.id)
      assert clone != nil
      assert clone.status == "backlog"
    end
  end

  describe "sweep/0 (SLA / WIP)" do
    test "finds overdue and stale tasks, ignores done" do
      workspace = ensure_workspace!()

      {:ok, _overdue} =
        Tasks.create_task(%{
          "workspace_id" => workspace.id,
          "title" => "Late",
          "due_date" => Date.add(Date.utc_today(), -3)
        })

      {:ok, _fresh} =
        Tasks.create_task(%{
          "workspace_id" => workspace.id,
          "title" => "On time",
          "due_date" => Date.add(Date.utc_today(), 3)
        })

      {:ok, done_late} =
        Tasks.create_task(%{
          "workspace_id" => workspace.id,
          "title" => "Done late",
          "due_date" => Date.add(Date.utc_today(), -3),
          "status" => "done"
        })

      # Ensure completed_at set so it's terminal
      Tasks.update_task(done_late, %{"completed_at" => DateTime.utc_now()})

      result = Automation.sweep()

      overdue_titles = Enum.map(result.overdue, & &1.title)
      assert "Late" in overdue_titles
      refute "On time" in overdue_titles
      refute "Done late" in overdue_titles
    end

    test "report body renders markdown with sections" do
      workspace = ensure_workspace!()

      {:ok, _} =
        Tasks.create_task(%{
          "workspace_id" => workspace.id,
          "title" => "Vencida",
          "due_date" => Date.add(Date.utc_today(), -1)
        })

      body = Automation.sweep() |> Automation.sweep_report_body()

      assert body =~ "# Task SLA / WIP sweep"
      assert body =~ "Vencida"
      assert body =~ "## Overdue"
    end
  end

  describe "job registry" do
    test "task_automation_daily is registered with a schedule" do
      assert Dran.Jobs.get(:task_automation_daily).mfa ==
               {Dran.Tasks.Automation, :run_scheduled, []}

      source = File.read!("config/config.exs")
      assert source =~ "task_automation_daily:"
    end
  end
end
