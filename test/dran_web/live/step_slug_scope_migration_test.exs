defmodule DranWeb.StepSlugScopeMigrationTest do
  @moduledoc """
  Regression: step.slug must be unique per WORKFLOW, not per workspace.

  Two different workflows should be able to both have a step called "build".
  Previously the constraint was (workspace_id, slug), which meant a step
  titled "Nuevo paso" created via `insert_step_between` on wf2 would fail
  because wf1 already had one.
  """
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.{DataCase, Workflows}

  test "two workflows can each have a step with the same title/slug", %{conn: conn} do
    ws = DataCase.ensure_workspace!()

    {:ok, wf1} =
      Workflows.create_workflow(%{
        "workspace_id" => ws.id,
        "title" => "Workflow Uno",
        "slug" => "wf-uno",
        "kind" => "one_shot",
        "status" => "draft"
      })

    {:ok, wf2} =
      Workflows.create_workflow(%{
        "workspace_id" => ws.id,
        "title" => "Workflow Dos",
        "slug" => "wf-dos",
        "kind" => "one_shot",
        "status" => "draft"
      })

    # Both workflows can create a step titled "build" independently.
    assert {:ok, _a1} = Workflows.create_step(wf1, %{"title" => "build", "slug" => "build"})
    assert {:ok, _a2} = Workflows.create_step(wf2, %{"title" => "build", "slug" => "build"})

    # Same for insert_step_between using the hardcoded "Nuevo paso" title.
    {:ok, s1a} = Workflows.create_step(wf1, %{"title" => "A", "slug" => "a"})
    {:ok, s1b} = Workflows.create_step(wf1, %{"title" => "B", "slug" => "b"})
    {:ok, _} = Dran.Contracts.add_dependency(s1b, s1a)

    {:ok, s2a} = Workflows.create_step(wf2, %{"title" => "X", "slug" => "x"})
    {:ok, s2b} = Workflows.create_step(wf2, %{"title" => "Y", "slug" => "y"})
    {:ok, _} = Dran.Contracts.add_dependency(s2b, s2a)

    # First workflow: insert succeeds.
    assert {:ok, inserted1} =
             Workflows.insert_step_between(wf1, s1b, s1a, %{"title" => "Nuevo paso"})

    # Second workflow: MUST also succeed (was failing before fix).
    assert {:ok, inserted2} =
             Workflows.insert_step_between(wf2, s2b, s2a, %{"title" => "Nuevo paso"})

    assert inserted1.title == "Nuevo paso"
    assert inserted2.title == "Nuevo paso"

    # Both share the same slug; they live in different workflows.
    assert inserted1.slug == inserted2.slug

    # Each still belongs to its original workflow.
    assert inserted1.workflow_id == wf1.id
    assert inserted2.workflow_id == wf2.id
  end

  test "same workflow rejects duplicate slugs", %{conn: conn} do
    ws = DataCase.ensure_workspace!()

    {:ok, wf} =
      Workflows.create_workflow(%{
        "workspace_id" => ws.id,
        "title" => "Dup WF",
        "slug" => "dup-wf",
        "kind" => "one_shot",
        "status" => "draft"
      })

    assert {:ok, _} = Workflows.create_step(wf, %{"title" => "Same", "slug" => "same"})

    # Duplicate slug in the SAME workflow should fail.
    assert {:error, cs} = Workflows.create_step(wf, %{"title" => "Other", "slug" => "same"})
    assert cs.errors[:slug] || cs.errors[:workflow_id]
  end
end
