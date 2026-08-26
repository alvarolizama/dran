defmodule Dran.Knowledge.PropsNormalizationTest do
  use Dran.DataCase, async: true

  alias Dran.Knowledge

  # create_page/update_page must decode the JSON string the props editor
  # submits under meta["props"] into a map before it hits the jsonb column —
  # otherwise props are stored as a scalar string the PropsMaterializer and
  # the meta->'props' query filters can't see.

  describe "create_page/1 props normalization" do
    setup do
      slug = "props-create-#{System.unique_integer([:positive, :monotonic])}"
      {:ok, workspace} = Knowledge.create_workspace(%{name: "Props Create #{slug}", slug: slug})
      %{workspace: workspace}
    end

    test "decodes a JSON object string into a map", %{workspace: workspace} do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: workspace.id,
          title: "Props page",
          page_type: "entity",
          meta: %{"props" => ~s({"role": "sales"})}
        })

      assert page.meta["props"] == %{"role" => "sales"}
    end

    test "drops invalid JSON props instead of storing a string", %{workspace: workspace} do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: workspace.id,
          title: "Bad props",
          page_type: "entity",
          meta: %{"props" => "not-json{"}
        })

      assert is_nil(page.meta["props"])
    end

    test "drops empty-string props", %{workspace: workspace} do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: workspace.id,
          title: "Empty props",
          page_type: "entity",
          meta: %{"props" => ""}
        })

      assert is_nil(page.meta["props"])
    end
  end

  describe "update_page/2 props normalization" do
    setup do
      slug = "props-norm-#{System.unique_integer([:positive, :monotonic])}"
      {:ok, workspace} = Knowledge.create_workspace(%{name: "Props Norm #{slug}", slug: slug})

      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: workspace.id,
          title: "Original",
          page_type: "entity",
          meta: %{"kind" => "person"}
        })

      %{page: page}
    end

    test "decodes a JSON string on update", %{page: page} do
      {:ok, updated} =
        Knowledge.update_page(page, %{"meta" => %{"props" => ~s({"tier": "vip"})}})

      assert updated.meta["props"] == %{"tier" => "vip"}
    end

    test "removes props when the editor is cleared", %{page: page} do
      {:ok, page2} = Knowledge.update_page(page, %{"meta" => %{"props" => ~s({"tier": "vip"})}})
      {:ok, updated} = Knowledge.update_page(page2, %{"meta" => %{"props" => ""}})

      assert is_nil(updated.meta["props"])
    end

    test "keeps map props untouched (non-form callers, e.g. MCP)", %{page: page} do
      {:ok, updated} =
        Knowledge.update_page(page, %{"meta" => %{"props" => %{"role" => "sales"}}})

      assert updated.meta["props"] == %{"role" => "sales"}
    end
  end
end
