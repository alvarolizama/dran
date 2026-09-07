defmodule DranWeb.ResourceComponentsChecklistTest do
  use DranWeb.ConnCase, async: true

  alias Dran.Task
  alias DranWeb.ResourceComponents

  describe "parse_checklist_param/1" do
    test "normalizes HTML array params (map keyed by index, done => \"on\")" do
      params = %{
        "0" => %{"text" => " first ", "done" => "on"},
        "1" => %{"text" => "second"},
        "2" => %{"text" => "   "}
      }

      assert ResourceComponents.parse_checklist_param(params) == [
               %{"text" => "first", "done" => true},
               %{"text" => "second", "done" => false}
             ]
    end

    test "keeps index order even when keys sort lexicographically wrong" do
      params = %{
        "10" => %{"text" => "last"},
        "2" => %{"text" => "early"}
      }

      assert ResourceComponents.parse_checklist_param(params) == [
               %{"text" => "early", "done" => false},
               %{"text" => "last", "done" => false}
             ]
    end

    test "accepts the stored/MCP shape (list of maps with booleans)" do
      list = [%{"text" => "a", "done" => true}, %{"text" => "b", "done" => false}]

      assert ResourceComponents.parse_checklist_param(list) == [
               %{"text" => "a", "done" => true},
               %{"text" => "b", "done" => false}
             ]
    end

    test "maps legacy atom keys defensively" do
      assert ResourceComponents.parse_checklist_param([%{text: "x", done: true}]) == [
               %{"text" => "x", "done" => true}
             ]
    end

    test "nil and garbage fall back to an empty list" do
      assert ResourceComponents.parse_checklist_param(nil) == []
      assert ResourceComponents.parse_checklist_param("nope") == []
    end
  end

  describe "current_checklist/2" do
    test "prefers the changeset's live :checklist change over persisted items" do
      task = %Task{checklist: [%{"text" => "persisted", "done" => false}]}

      changeset =
        Task.update_changeset(task, %{"checklist" => [%{"text" => "edited", "done" => true}]})

      assert ResourceComponents.current_checklist(task, changeset) == [
               %{"text" => "edited", "done" => true}
             ]
    end

    test "falls back to the persisted checklist without a change" do
      task = %Task{checklist: [%{"text" => "kept", "done" => false}]}
      changeset = Task.update_changeset(task, %{"title" => "t"})

      assert ResourceComponents.current_checklist(task, changeset) == [
               %{"text" => "kept", "done" => false}
             ]
    end

    test "drops empty-text items and accepts a form source" do
      task = %Task{}

      changeset =
        Task.update_changeset(task, %{
          "checklist" => [%{"text" => "", "done" => false}, %{"text" => "real", "done" => false}]
        })

      form = Phoenix.Component.to_form(changeset, as: :task)

      assert ResourceComponents.current_checklist(task, form) == [
               %{"text" => "real", "done" => false}
             ]
    end
  end

  describe "checklist_rows/2" do
    test "maps persisted items and always appends the trailing add row" do
      task = %Task{
        checklist: [%{"text" => "one", "done" => true}, %{"text" => "two", "done" => false}]
      }

      changeset = Task.update_changeset(task, %{})

      rows = ResourceComponents.checklist_rows(task, changeset)

      assert [
               %{id: "checklist-row-0", text: "one", done: true, persisted: true},
               %{id: "checklist-row-1", text: "two", done: false, persisted: true},
               %{id: "checklist-row-next", persisted: false}
             ] = rows
    end

    test "an empty checklist still renders the add row" do
      rows = ResourceComponents.checklist_rows(%Task{}, Task.update_changeset(%Task{}, %{}))

      assert [%{id: "checklist-row-next", index: 0, persisted: false}] = rows
    end

    test "unknown sources degrade to a single add row" do
      assert [%{id: "checklist-row-next"}] = ResourceComponents.checklist_rows(nil, nil)
    end
  end
end
