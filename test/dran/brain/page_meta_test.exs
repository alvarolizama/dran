defmodule Dran.Brain.PageMetaTest do
  # Pure embedded-schema module — no DB access needed. ExUnit.Case is enough
  # (we deliberately avoid Dran.DataCase so these tests don't spin up the
  # sandbox for no reason). The `errors_on/1` helper is inlined below.
  use ExUnit.Case, async: true

  alias Dran.Brain.PageMeta

  # ── helpers ────────────────────────────────────────────────────────────────

  # Same helper as Dran.DataCase.errors_on/1, inlined to avoid the DB sandbox.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp cs(page_type, attrs) when is_map(attrs) do
    PageMeta.changeset(%PageMeta{}, attrs, page_type)
  end

  # ── Task 1.11 — derive_project_health/1 ────────────────────────────────────

  describe "derive_project_health/1" do
    test "green, green, yellow → yellow (avg = 2.67, floor = 2)" do
      # scores: 3 + 3 + 2 = 8; avg = 8/3 ≈ 2.667; floor(2.667) = 2 → "yellow"
      assert PageMeta.derive_project_health(["green", "green", "yellow"]) == "yellow"
    end

    test "green, red → yellow (avg = 2.0, floor = 2)" do
      # scores: 3 + 1 = 4; avg = 4/2 = 2.0; floor(2.0) = 2 → "yellow"
      assert PageMeta.derive_project_health(["green", "red"]) == "yellow"
    end

    test "empty list → nil" do
      assert is_nil(PageMeta.derive_project_health([]))
    end

    test "all green → green (avg = 3.0)" do
      assert PageMeta.derive_project_health(["green", "green"]) == "green"
    end

    test "all red → red (avg = 1.0)" do
      assert PageMeta.derive_project_health(["red", "red", "red"]) == "red"
    end

    test "unknown healths are ignored" do
      # plan spec §2.8: Enum.reject(&is_nil/1) on the looked-up scores.
      # ["green", "bogus"] → [3] → avg 3.0 → "green"
      assert PageMeta.derive_project_health(["green", "bogus"]) == "green"
    end
  end

  # ── Task 1.11 — derive_goal_progress/1 ───────────────────────────────────────

  describe "derive_goal_progress/1" do
    test "done, done, in_progress → ~0.67 (2/3)" do
      result = PageMeta.derive_goal_progress(["done", "done", "in_progress"])
      # 2/3 = 0.6666… → Float.round to 2 dp for the comparison.
      assert Float.round(result, 2) == 0.67
    end

    test "done, cancelled → 1.0 (cancelled excluded from denominator)" do
      result = PageMeta.derive_goal_progress(["done", "cancelled"])
      assert_in_delta(result, 1.0, 0.001)
    end

    test "empty list → nil" do
      assert is_nil(PageMeta.derive_goal_progress([]))
    end

    test "all cancelled → nil (no relevant todos)" do
      # plan spec §2.9: reject cancelled → [] → nil.
      assert is_nil(PageMeta.derive_goal_progress(["cancelled", "cancelled"]))
    end

    test "single done → 1.0" do
      assert_in_delta(PageMeta.derive_goal_progress(["done"]), 1.0, 0.001)
    end

    test "single in_progress → 0.0" do
      assert_in_delta(PageMeta.derive_goal_progress(["in_progress"]), 0.0, 0.001)
    end
  end

  # ── Task 1.11 — changeset validations per page type ────────────────────────

  describe "changeset/3 — page_type validations" do
    test "project with invalid status is invalid" do
      # Per plan: @project_statuses ~w(draft active on_hold done archived)
      # "blocked" is not allowed.
      changeset =
        cs("project", %{
          "status" => "blocked",
          "priority" => "high",
          "health" => "green",
          "health_source" => "manual"
        })

      refute changeset.valid?
      assert Map.has_key?(errors_on(changeset), :status)
    end

    test "goal with progress = 1.5 is invalid" do
      # validate_progress_range/1 must reject progress outside [0.0, 1.0].
      changeset =
        cs("goal", %{
          "progress" => 1.5,
          "health" => "green"
        })

      refute changeset.valid?
      assert Map.has_key?(errors_on(changeset), :progress)
    end

    test "plan with status = on_hold is invalid (only draft/active/done/archived)" do
      # plan spec §2.5: @plan_statuses ~w(draft active done archived)  # no on_hold
      changeset =
        cs("plan", %{
          "status" => "on_hold",
          "horizon" => "weekly"
        })

      refute changeset.valid?
      assert Map.has_key?(errors_on(changeset), :status)
    end

    test "note with kind = reminder is valid" do
      # Plan Task 1.4 adds "reminder" to @note_kinds.
      changeset = cs("note", %{"kind" => "reminder"})

      assert changeset.valid?
    end
  end

  # ── Graph signals — pagerank / community_id ────────────────────────────────

  describe "graph fields (pagerank, community_id)" do
    test "accepts pagerank and community_id in meta" do
      attrs = %{"pagerank" => 0.42, "community_id" => 3}
      changeset = PageMeta.changeset(%PageMeta{}, attrs, "note")

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :pagerank) == 0.42
      assert Ecto.Changeset.get_change(changeset, :community_id) == 3
    end

    test "accepts pagerank alone" do
      changeset = cs("note", %{"pagerank" => 0.123})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :pagerank) == 0.123
    end

    test "accepts community_id alone" do
      changeset = cs("note", %{"community_id" => 7})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :community_id) == 7
    end
  end
end
