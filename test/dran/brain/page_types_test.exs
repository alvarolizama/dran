defmodule Dran.Brain.PageTypesTest do
  use ExUnit.Case, async: true

  alias Dran.Brain.Page
  alias Dran.Brain.PageTypes

  describe "types/0" do
    test "returns the 10 canonical page types in order" do
      assert PageTypes.types() ==
               ~w(note plan todo goal entity concept reference query project report)
    end

    test "is the single source for Page.all_types/0" do
      assert Page.all_types() == PageTypes.types()
      assert "report" in Page.all_types()
    end
  end

  describe "capabilities" do
    test "report is a second-citizen page: every capability is false" do
      refute PageTypes.graph?("report")
      refute PageTypes.journey?("report")
      refute PageTypes.embeddings?("report")
      refute PageTypes.mcp_create?("report")
    end

    test "todo and plan are hidden from the graph but keep everything else" do
      for type <- ~w(todo plan) do
        refute PageTypes.graph?(type)
        assert PageTypes.journey?(type)
        assert PageTypes.embeddings?(type)
        assert PageTypes.mcp_create?(type)
      end
    end

    test "note is a full citizen: every capability is true" do
      assert PageTypes.graph?("note")
      assert PageTypes.journey?("note")
      assert PageTypes.embeddings?("note")
      assert PageTypes.mcp_create?("note")
    end

    test "all full-citizen types have every capability enabled" do
      for type <- ~w(note goal entity concept reference query project) do
        assert PageTypes.graph?(type), "#{type} should be in the graph"
        assert PageTypes.journey?(type), "#{type} should be in the journey"
        assert PageTypes.embeddings?(type), "#{type} should have embeddings"
        assert PageTypes.mcp_create?(type), "#{type} should be creatable via MCP"
      end
    end

    test "unknown types default to permissive (pre-registry behaviour)" do
      assert PageTypes.graph?("nonexistent")
      assert PageTypes.journey?("nonexistent")
      assert PageTypes.embeddings?("nonexistent")
      assert PageTypes.mcp_create?("nonexistent")
    end
  end

  describe "list helpers" do
    test "hidden_from_graph/0 returns exactly todo, plan and report" do
      assert Enum.sort(PageTypes.hidden_from_graph()) == ~w(plan report todo)
    end

    test "excluded_from_journey/0 returns exactly report" do
      assert PageTypes.excluded_from_journey() == ["report"]
    end
  end
end
