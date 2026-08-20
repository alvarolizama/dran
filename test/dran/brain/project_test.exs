defmodule Dran.ProjectTest do
  use Dran.DataCase, async: false

  alias Dran.Brain

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
      rerank_model: nil,
      timeout: 100,
      schedule_async: false
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    context =
      Brain.get_workspace_by_slug("personal") ||
        elem(Brain.create_workspace(%{name: "Personal", slug: "personal"}), 1)

    {:ok, context: context}
  end

  describe "create_project/1" do
    test "creates a project with valid attrs", %{context: ctx} do
      attrs = %{
        workspace_id: ctx.id,
        title: "Test Project",
        slug: "test-project",
        status: "active",
        priority: "medium"
      }

      assert {:ok, %Brain.Project{} = project} = Brain.create_project(attrs)
      assert project.title == "Test Project"
      assert project.status == "active"
    end
  end

  describe "get_project_by_slug/2" do
    test "retrieves a project by slug and workspace_id", %{context: ctx} do
      {:ok, created} =
        Brain.create_project(%{
          workspace_id: ctx.id,
          title: "Findable Project",
          slug: "findable-project",
          status: "active"
        })

      found = Brain.get_project_by_slug("findable-project", ctx.id)
      assert found.id == created.id
    end
  end

  describe "list_projects/1" do
    test "lists projects in a workspace", %{context: ctx} do
      {:ok, _} =
        Brain.create_project(%{
          workspace_id: ctx.id,
          title: "Project A",
          slug: "project-a",
          status: "active"
        })

      {:ok, _} =
        Brain.create_project(%{
          workspace_id: ctx.id,
          title: "Project B",
          slug: "project-b",
          status: "active"
        })

      projects = Brain.list_projects(workspace_id: ctx.id)
      assert length(projects) == 2
    end
  end
end
