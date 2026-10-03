defmodule Dran.RelationsCleanupTest do
  @moduledoc """
  Gate W4b (contract.md): borrar no deja aristas huérfanas.

  `relations` es polimórfica y no tiene FK (F29): borrar un goal o una página
  limpia sus aristas en el contexto, y borrar un goal limpia también las de
  sus tasks (que caen por `on_delete: :delete_all`). Una relación huérfana es
  un nodo muerto en el grafo (P12 / Constraint 15).
  """

  use Dran.DataCase, async: false

  alias Dran.{Accounts, Goals, Knowledge, Relation, Tasks}

  setup do
    ws = Dran.DataCase.ensure_workspace!()
    {:ok, owner: member!("owner"), ws: ws}
  end

  test "borrar una página limpia sus aristas", %{ws: ws, owner: owner} do
    p1 = page!(ws, owner, "P1")
    p2 = page!(ws, owner, "P2")

    {:ok, _} =
      Knowledge.create_relation(%{
        source_id: p1.id,
        source_type: "page",
        target_id: p2.id,
        target_type: "page",
        relation_type: "related"
      })

    refute edges_touching(p1.id) == []
    assert {:ok, _} = Knowledge.delete_page(p1)
    assert edges_touching(p1.id) == []
  end

  test "borrar un goal limpia sus aristas y las de sus tasks", %{ws: ws, owner: owner} do
    page = page!(ws, owner, "P")
    goal = goal!(owner)
    {:ok, task} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Task"})

    {:ok, _} =
      Knowledge.create_relation(%{
        source_id: task.id,
        source_type: "task",
        target_id: goal.id,
        target_type: "goal",
        relation_type: "part_of"
      })

    {:ok, _} =
      Knowledge.create_relation(%{
        source_id: task.id,
        source_type: "task",
        target_id: page.id,
        target_type: "page",
        relation_type: "part_of"
      })

    {:ok, _} =
      Knowledge.create_relation(%{
        source_id: goal.id,
        source_type: "goal",
        target_id: page.id,
        target_type: "page",
        relation_type: "related"
      })

    refute edges_touching(goal.id) == []
    refute edges_touching(task.id) == []

    assert {:ok, _} = Goals.delete_goal(goal)

    assert Repo.get(Dran.Tasks.Task, task.id) == nil
    assert edges_touching(goal.id) == []
    assert edges_touching(task.id) == []
  end

  test "mover una task no rompe el grafo (sus aristas sobreviven)", %{ws: ws, owner: owner} do
    page = page!(ws, owner, "P")
    a = goal!(owner)
    b = goal!(owner)
    {:ok, task} = Tasks.create_task(%{"goal_id" => a.id, "title" => "Task"})

    {:ok, _} =
      Knowledge.create_relation(%{
        source_id: task.id,
        source_type: "task",
        target_id: page.id,
        target_type: "page",
        relation_type: "part_of"
      })

    assert {:ok, _} = Tasks.move_task(task, %{"goal_id" => b.id})
    assert length(edges_touching(task.id)) == 1
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp edges_touching(id) do
    Repo.all(from r in Relation, where: r.source_id == ^id or r.target_id == ^id)
  end

  defp page!(ws, owner, prefix) do
    {:ok, page} =
      Knowledge.create_page(%{
        workspace_id: ws.id,
        title: "#{prefix} #{uniq()}",
        page_type: "note",
        owner_user_id: owner.id
      })

    page
  end

  defp goal!(owner, extra \\ %{}) do
    {:ok, goal} =
      Goals.create_goal(
        Map.merge(%{"title" => "Meta #{uniq()}", "owner_user_id" => owner.id}, extra)
      )

    goal
  end

  defp member!(label) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "#{label}-#{unique}@dran.test",
        api_token: "tok-#{label}-#{unique}"
      })

    user
  end

  defp uniq, do: System.unique_integer([:positive])
end
