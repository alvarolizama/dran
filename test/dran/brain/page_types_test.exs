defmodule Dran.Brain.PageTypesTest do
  use ExUnit.Case, async: true

  alias Dran.Page
  alias Dran.PageTypes

  describe "types/0" do
    test "returns the 4 canonical page types in order" do
      assert PageTypes.types() ==
               ~w(note entity concept reference)
    end

    test "is the single source for Page.all_types/0" do
      assert Page.all_types() == PageTypes.types()
      refute "report" in Page.all_types()
    end
  end

  describe "capabilities" do
    test "note is a full citizen: every capability is true" do
      assert PageTypes.graph?("note")
      assert PageTypes.journey?("note")
      assert PageTypes.embeddings?("note")
      assert PageTypes.mcp_create?("note")
    end

    test "all full-citizen types have every capability enabled" do
      for type <- ~w(note entity concept reference) do
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
    test "hidden_from_graph/0 returns empty for standard types" do
      # goal, plan, todo, and report have been removed from the page types registry
      # or handled elsewhere. The PageTypes module now only contains 4 standard types.
      assert PageTypes.hidden_from_graph() == []
    end

    test "excluded_from_journey/0 returns empty for standard types" do
      assert PageTypes.excluded_from_journey() == []
    end
  end
end
