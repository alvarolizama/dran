defmodule Dran.TasksMigrationTest do
  @moduledoc """
  Tests the notes kind:todo → tasks data migration
  (20260826061747_migrate_todo_notes_to_tasks.exs) by running the actual
  migration file through Ecto.Migrator against the sandboxed test DB.

  Invariants:

    - every todo-note became a task row (same id)
    - kanban columns mapped (unknown/NULL → backlog)
    - completed_at set when status is done/cancelled
    - goal links (meta.goal_slug) became part_of task→goal relations
    - the source notes are gone, plain notes untouched
    - re-running is a no-op (idempotent)
  """

  use Dran.DataCase, async: false

  alias Dran.{Knowledge, Repo}

  setup do
    workspace = ensure_workspace!()

    # Migrations are not compiled into the test env by default — load the
    # module on demand so its SQL statements can run inside the sandbox.
    unless function_exported?(Dran.Repo.Migrations.MigrateTodoNotesToTasks, :up_statements, 0) do
      Code.eval_file(
        Path.expand(
          "../../priv/repo/migrations/20260826061747_migrate_todo_notes_to_tasks.exs",
          __DIR__
        )
      )
    end

    %{workspace: workspace}
  end

  defp insert_todo_note!(workspace_id, slug, status, goal_slug \\ nil) do
    meta = %{"kind" => "todo"}

    meta =
      if status, do: Map.put(meta, "kanban_status", status), else: meta

    meta =
      if goal_slug, do: Map.put(meta, "goal_slug", goal_slug), else: meta

    {:ok, page} =
      Knowledge.create_page(%{
        "workspace_id" => workspace_id,
        "title" => String.replace(slug, "-", " "),
        "slug" => slug,
        "page_type" => "note",
        "meta" => meta
      })

    page
  end

  test "migrates todo notes to tasks with relations", %{workspace: ws} do
    {:ok, goal} =
      Dran.Goals.create_goal(%{
        "workspace_id" => ws.id,
        "title" => "Goal A",
        "slug" => "goal-a"
      })

    linked = insert_todo_note!(ws.id, "todo-linked", "done", "goal-a")
    unlinked = insert_todo_note!(ws.id, "todo-unlinked", nil, nil)
    legacy_status = insert_todo_note!(ws.id, "todo-legacy", "pending", nil)

    {:ok, _plain} =
      Knowledge.create_page(%{
        "workspace_id" => ws.id,
        "title" => "Plain note",
        "slug" => "plain-note",
        "page_type" => "note",
        "meta" => %{"kind" => "journal"}
      })

    run_migration_up!()

    # 1. Tasks exist with the same ids, statuses mapped
    assert Repo.get(Dran.Task, linked.id).status == "done"
    assert Repo.get(Dran.Task, unlinked.id).status == "backlog"
    # 'pending' is not a valid task status → coalesced to backlog
    assert Repo.get(Dran.Task, legacy_status.id).status == "backlog"

    # 2. completed_at set for done tasks
    refute is_nil(Repo.get(Dran.Task, linked.id).completed_at)

    # 3. Goal link became a part_of task→goal relation
    goal_edges =
      Repo.all(
        from r in Dran.Relation,
          where:
            r.source_type == "task" and r.target_type == "goal" and
              r.relation_type == "part_of" and r.target_id == ^goal.id
      )

    assert length(goal_edges) == 1
    assert hd(goal_edges).source_id == linked.id

    # 4. Source notes are gone
    assert is_nil(Knowledge.get_page_by_slug("todo-linked", ws.id))
    assert is_nil(Knowledge.get_page_by_slug("todo-unlinked", ws.id))

    # 5. Plain note untouched
    refute is_nil(Knowledge.get_page_by_slug("plain-note", ws.id))

    # 6. Idempotent: re-running moves nothing new
    run_migration_up!()
    assert Repo.aggregate(Dran.Task, :count) == 3
  end

  test "relations pointing at a todo-note are rewritten to task endpoints", %{workspace: ws} do
    todo = insert_todo_note!(ws.id, "todo-related", "backlog", nil)

    {:ok, other} =
      Knowledge.create_page(%{
        "workspace_id" => ws.id,
        "title" => "Other note",
        "slug" => "other-note",
        "page_type" => "note",
        "meta" => %{"kind" => "idea"}
      })

    # other → todo (todo as target of a relation)
    {:ok, _} =
      Knowledge.create_relation(%{
        source_id: other.id,
        target_id: todo.id,
        relation_type: "related"
      })

    run_migration_up!()

    rel =
      Repo.one(
        from r in Dran.Relation,
          where: r.source_id == ^other.id and r.target_id == ^todo.id
      )

    # target flipped page→task
    assert rel.target_type == "task"
    assert rel.source_type == "page"
  end

  # Runs the real migration SQL inside the test sandbox.
  defp run_migration_up! do
    # The historical migration copies pages.summary into tasks.summary, but
    # tasks.summary was dropped later (dead column cleanup — migration
    # 20260903012228). Re-add it inside the sandbox transaction so the
    # replay works; the per-test rollback removes it again.
    Repo.query!("ALTER TABLE tasks ADD COLUMN IF NOT EXISTS summary varchar(255)")

    Enum.each(
      Dran.Repo.Migrations.MigrateTodoNotesToTasks.up_statements(),
      &Repo.query!/1
    )
  end
end
