defmodule Dran.TasksTest do
  use Dran.DataCase, async: false

  alias Dran.{Tasks, Task}

  describe "create_task/1" do
    test "creates a standalone task with defaults" do
      workspace = ensure_workspace!()

      {:ok, task} =
        Tasks.create_task(%{
          "workspace_id" => workspace.id,
          "title" => "Review PR"
        })

      assert task.title == "Review PR"
      assert task.status == "backlog"
      assert task.recurrence == "none"
      assert task.position >= 100
      assert task.slug =~ "review-pr"
      assert task.owner == "system"
      assert task.created_by == "system"
    end

    test "generates a unique slug within the workspace" do
      workspace = ensure_workspace!()

      {:ok, _first} =
        Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Write docs"})

      {:ok, second} =
        Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Write docs"})

      # Second task with same title gets a different slug
      assert second.slug != "write-docs"
      assert String.starts_with?(second.slug, "write-docs")
    end

    test "validates required fields" do
      {:error, changeset} = Tasks.create_task(%{"title" => "No workspace"})

      assert "can't be blank" in errors_on(changeset).workspace_id
    end

    test "validates status inclusion" do
      workspace = ensure_workspace!()

      {:error, changeset} =
        Tasks.create_task(%{
          "workspace_id" => workspace.id,
          "title" => "Bad status",
          "status" => "bogus"
        })

      assert "is invalid" in errors_on(changeset).status
    end

    test "accepts a checklist in meta" do
      workspace = ensure_workspace!()

      {:ok, task} =
        Tasks.create_task(%{
          "workspace_id" => workspace.id,
          "title" => "Launch feature",
          "meta" => %{
            "checklist" => [%{"text" => "Write tests", "done" => false}]
          }
        })

      assert task.meta["checklist"] == [%{"text" => "Write tests", "done" => false}]
    end
  end

  describe "list_board/1" do
    test "returns all columns even when empty" do
      workspace = ensure_workspace!()
      board = Tasks.list_board(workspace.id)

      for status <- Task.statuses() do
        assert Map.has_key?(board, status)
        assert board[status] == []
      end
    end

    test "groups tasks by status ordered by position" do
      workspace = ensure_workspace!()

      {:ok, t1} =
        Tasks.create_task(%{
          "workspace_id" => workspace.id,
          "title" => "First",
          "status" => "backlog"
        })

      {:ok, _t2} =
        Tasks.create_task(%{
          "workspace_id" => workspace.id,
          "title" => "Second",
          "status" => "in_progress"
        })

      {:ok, t3} =
        Tasks.create_task(%{
          "workspace_id" => workspace.id,
          "title" => "Third",
          "status" => "backlog"
        })

      board = Tasks.list_board(workspace.id)

      assert length(board["backlog"]) == 2
      assert length(board["in_progress"]) == 1
      # Ordered by position ascending
      backlog_titles = Enum.map(board["backlog"], & &1.title)
      assert backlog_titles == ["First", "Third"]
      # t1 was created first so has lower position than t3
      assert Enum.find(board["backlog"], &(&1.id == t1.id)).position <
               Enum.find(board["backlog"], &(&1.id == t3.id)).position
    end
  end

  describe "move_task/3" do
    test "moves a task to a new column" do
      workspace = ensure_workspace!()

      {:ok, task} =
        Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Move me"})

      assert task.status == "backlog"

      {:ok, moved} = Tasks.move_task(task, "in_progress")

      assert moved.status == "in_progress"
      assert moved.lock_version == task.lock_version + 1
    end

    test "returns :stale on lock_version conflict" do
      workspace = ensure_workspace!()

      {:ok, task} =
        Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Concurrent"})

      # Simulate a stale lock_version (another client moved it first)
      stale_task = %{task | lock_version: task.lock_version - 1}

      assert {:error, :stale} = Tasks.move_task(stale_task, "done")
    end

    test "insert before a specific task" do
      workspace = ensure_workspace!()

      {:ok, t1} =
        Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "A"})

      {:ok, t2} =
        Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "B"})

      # Move t2 before t1
      {:ok, moved} = Tasks.move_task(t2, "backlog", before_id: t1.id)

      assert moved.position < t1.position
    end
  end

  describe "update_task/2" do
    test "updates task fields" do
      workspace = ensure_workspace!()

      {:ok, task} =
        Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Original"})

      {:ok, updated} = Tasks.update_task(task, %{"title" => "Updated", "priority" => "high"})

      assert updated.title == "Updated"
      assert updated.priority == "high"
    end
  end

  describe "max_position/2" do
    test "returns 0 for an empty column" do
      workspace = ensure_workspace!()
      assert Tasks.max_position(workspace.id, "backlog") == 0
    end

    test "returns the highest position in the column" do
      workspace = ensure_workspace!()

      {:ok, _task} =
        Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Task"})

      pos = Tasks.max_position(workspace.id, "backlog")
      assert pos >= 100
    end
  end
end
