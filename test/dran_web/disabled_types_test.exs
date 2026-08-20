defmodule DranWeb.DisabledTypesTest do
  use ExUnit.Case, async: true

  alias Dran.Brain.Workspace
  alias DranWeb.DisabledTypes

  defp ctx(disabled), do: %Workspace{disabled_page_types: disabled}

  @tabs [
    {"goals", "Goals"},
    {"plans", "Plans"},
    {"todos", "Todos"},
    {"graph", "Graph"}
  ]

  describe "visible_tabs/2" do
    test "returns all tabs when nothing is disabled" do
      assert DisabledTypes.visible_tabs(@tabs, ctx([])) == @tabs
      assert DisabledTypes.visible_tabs(@tabs, ctx(nil)) == @tabs
    end

    test "filters out disabled types" do
      result = DisabledTypes.visible_tabs(@tabs, ctx(["goal", "todo"]))
      keys = Enum.map(result, &elem(&1, 0))
      assert keys == ["plans", "graph"]
    end

    test "graph tab is never filtered" do
      result = DisabledTypes.visible_tabs(@tabs, ctx(["todo", "goal", "plan"]))
      keys = Enum.map(result, &elem(&1, 0))
      assert "graph" in keys
    end
  end

  describe "tab_enabled?/2" do
    test "graph is always enabled" do
      assert DisabledTypes.tab_enabled?("graph", ctx(["todo", "goal", "plan"]))
    end

    test "returns false for disabled types" do
      refute DisabledTypes.tab_enabled?("todos", ctx(["todo"]))
      refute DisabledTypes.tab_enabled?("goals", ctx(["goal"]))
    end

    test "returns true for enabled types" do
      assert DisabledTypes.tab_enabled?("todos", ctx(["goal"]))
      assert DisabledTypes.tab_enabled?("plans", ctx([]))
    end
  end
end
