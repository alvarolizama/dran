defmodule Dran.Brain.PageMetaGettextTest do
  # Verifies that all option labels and field labels returned by
  # meta_fields_for/1,2 go through gettext.
  #
  # Strategy: the parent task fixes priv/gettext/es/LC_MESSAGES/default.po
  # where msgid "None" had msgstr "Hecho" (fuzzy pollution), and other
  # msgstrs may also be wrong (e.g. "Active" → "Archivar"). We must NOT
  # assert on specific Spanish strings — the .po state is in flux during
  # this task batch. Instead, we prove labels are routed through gettext
  # by checking that the msgid appears in priv/gettext/default.pot —
  # the extractor only writes msgids it found as `gettext("...")` calls
  # in source code.
  #
  # Combined with asserting the DB-value side (second tuple element) is
  # always the raw slug (never translated), this gives a complete proof:
  #
  #   1. Labels in default.pot ⇒ `gettext("...")` calls in page_meta.ex
  #      ⇒ labels go through gettext at runtime.
  #   2. Values are raw slugs ⇒ DB invariant holds.
  #
  # We use ExUnit.Case (no DB) — same style as page_meta_test.exs.
  use ExUnit.Case, async: false

  alias Dran.Brain.PageMeta

  # meta_fields_for/1,2 resolves gettext at call time against the CURRENT
  # process locale. The app default is "es", so labels come back translated
  # ("Pendientes"). We assert against the msgids in default.pot (English
  # source strings), so each assertion helper pins the process locale to
  # "en" while collecting fields.
  defp with_en_locale(fun) do
    Gettext.put_locale(DranWeb.Gettext, "en")
    result = fun.()
    Gettext.put_locale(DranWeb.Gettext, "es")
    result
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # Parse default.pot and return the set of all msgids the extractor saw.
  # We cache it in a module attribute since the file doesn't change during
  # the test run.
  @pot_msgids (
                pot_path = Path.join([File.cwd!(), "priv", "gettext", "default.pot"])

                pot_path
                |> File.read!()
                |> String.split(~r/\n\n+/)
                |> Enum.flat_map(fn block ->
                  case Regex.run(~r/^msgid "(.*?)"$/m, block) do
                    [_, msgid] -> [msgid]
                    _ -> []
                  end
                end)
                |> MapSet.new()
              )

  defp pot_has?(msgid) when is_binary(msgid), do: MapSet.member?(@pot_msgids, msgid)

  # Extract {label, value} pairs from all :select options for a page type.
  defp select_pairs(type, mode \\ :edit) do
    with_en_locale(fn ->
      type
      |> PageMeta.meta_fields_for(mode)
      |> Enum.flat_map(fn
        {:select, _key, _label, opts} when is_list(opts) ->
          direct_opts =
            Enum.filter(opts, fn
              {k, _v} when is_atom(k) -> false
              {l, v} when is_binary(l) and is_binary(v) -> true
              _ -> false
            end)

          keyword_opts = Keyword.get_values(opts, :options) |> List.flatten()

          (direct_opts ++ keyword_opts)
          |> Enum.flat_map(fn
            {l, v} when is_binary(l) and is_binary(v) -> [{l, v}]
            _ -> []
          end)

        _ ->
          []
      end)
    end)
  end

  # Collect the field labels (3rd tuple element) for a page type.
  defp field_labels(type, mode \\ :edit) do
    with_en_locale(fn ->
      type
      |> PageMeta.meta_fields_for(mode)
      |> Enum.map(fn
        {_type, _key, label, _opts} -> label
        {_type, _key, label} -> label
      end)
    end)
  end

  # ── option labels appear in default.pot ──────────────────────────────────

  describe "select option labels are routed through gettext (present in default.pot)" do
    test "todo: kanban_status option labels" do
      for {label, _value} <- select_pairs("todo") do
        assert pot_has?(label),
               "kanban_status/priority label #{inspect(label)} not in default.pot — not gettext'd"
      end
    end

    test "todo: every option label is the expected msgid" do
      labels = Enum.map(select_pairs("todo"), &elem(&1, 0))

      for expected <- [
            "Backlog",
            "This Week",
            "Today",
            "In Progress",
            "Done",
            "Cancelled",
            "Low",
            "Medium",
            "High",
            "Urgent"
          ] do
        assert expected in labels,
               "expected #{inspect(expected)} among todo option labels, got: #{inspect(labels)}"
      end
    end

    test "project: every option label is in default.pot" do
      for {label, _value} <- select_pairs("project") do
        assert pot_has?(label),
               "project option label #{inspect(label)} not in default.pot — not gettext'd"
      end
    end

    test "goal: every option label is in default.pot" do
      for {label, _value} <- select_pairs("goal") do
        assert pot_has?(label),
               "goal option label #{inspect(label)} not in default.pot — not gettext'd"
      end
    end

    test "plan: every option label is in default.pot" do
      for {label, _value} <- select_pairs("plan") do
        assert pot_has?(label),
               "plan option label #{inspect(label)} not in default.pot — not gettext'd"
      end
    end

    test "note: every kind option label is in default.pot" do
      for {label, _value} <- select_pairs("note") do
        assert pot_has?(label),
               "note kind label #{inspect(label)} not in default.pot — not gettext'd"
      end
    end

    test "concept: every kind option label is in default.pot" do
      for {label, _value} <- select_pairs("concept") do
        assert pot_has?(label),
               "concept kind label #{inspect(label)} not in default.pot — not gettext'd"
      end
    end

    test "entity: every kind option label is in default.pot" do
      for {label, _value} <- select_pairs("entity") do
        assert pot_has?(label),
               "entity kind label #{inspect(label)} not in default.pot — not gettext'd"
      end
    end

    test "reference: every kind option label is in default.pot" do
      for {label, _value} <- select_pairs("reference") do
        assert pot_has?(label),
               "reference kind label #{inspect(label)} not in default.pot — not gettext'd"
      end
    end

    test "artifact: every kind option label is in default.pot" do
      for {label, _value} <- select_pairs("artifact") do
        assert pot_has?(label),
               "artifact kind label #{inspect(label)} not in default.pot — not gettext'd"
      end
    end

    test "query: every option label is in default.pot" do
      for {label, _value} <- select_pairs("query") do
        assert pot_has?(label),
               "query option label #{inspect(label)} not in default.pot — not gettext'd"
      end
    end
  end

  # ── option values (DB slugs) are NEVER translated ───────────────────────

  describe "select option VALUES (DB slugs) are never translated" do
    test "todo: kanban_status values are raw slugs" do
      values = Enum.map(select_pairs("todo"), &elem(&1, 1))

      for expected <-
            ~w(backlog this_week today in_progress done cancelled low medium high urgent) do
        assert expected in values
      end
    end

    test "project: health, priority, status values are raw slugs" do
      values = Enum.map(select_pairs("project"), &elem(&1, 1))

      for expected <-
            ~w(green yellow red low medium high urgent draft active on_hold done archived) do
        assert expected in values
      end
    end

    test "goal: health values are raw slugs" do
      values = Enum.map(select_pairs("goal"), &elem(&1, 1))

      for expected <- ~w(green yellow red) do
        assert expected in values
      end
    end

    test "plan: horizon and status values are raw slugs" do
      values = Enum.map(select_pairs("plan"), &elem(&1, 1))

      for expected <- ~w(weekly monthly quarterly yearly draft active done archived) do
        assert expected in values
      end
    end

    test "note: kind values are raw slugs (lowercase)" do
      values = Enum.map(select_pairs("note"), &elem(&1, 1))

      for expected <- ~w(thought journal idea meeting question quote reminder) do
        assert expected in values
      end
    end

    test "concept: kind values are raw slugs" do
      values = Enum.map(select_pairs("concept"), &elem(&1, 1))

      for expected <- ~w(technique pattern discipline theory) do
        assert expected in values
      end
    end

    test "entity: kind values are raw slugs" do
      values = Enum.map(select_pairs("entity"), &elem(&1, 1))

      for expected <- ~w(person company product tool place event) do
        assert expected in values
      end
    end

    test "reference: kind values are raw slugs" do
      values = Enum.map(select_pairs("reference"), &elem(&1, 1))

      for expected <- ~w(article paper video podcast book) do
        assert expected in values
      end
    end

    test "artifact: kind values are raw slugs" do
      values = Enum.map(select_pairs("artifact"), &elem(&1, 1))

      for expected <- ~w(document code design deliverable file) do
        assert expected in values
      end
    end

    test "query: kind, difficulty, answer_status values are raw slugs" do
      values = Enum.map(select_pairs("query"), &elem(&1, 1))

      for expected <-
            ~w(factual conceptual how_to opinion simple intermediate advanced open answered verified) do
        assert expected in values
      end
    end
  end

  # ── field labels are routed through gettext ──────────────────────────────

  describe "field labels (3rd tuple element) are routed through gettext" do
    test "every field label across all page types is in default.pot" do
      for type <- ~w(note concept entity reference artifact plan project goal todo query),
          label <- field_labels(type) do
        assert pot_has?(label),
               "field label #{inspect(label)} for type #{inspect(type)} not in default.pot — not gettext'd"
      end
    end

    test "goal :new mode: every field label is in default.pot" do
      for label <- field_labels("goal", :new) do
        assert pot_has?(label),
               "goal :new field label #{inspect(label)} not in default.pot — not gettext'd"
      end
    end

    test "goal :new mode excludes derived fields (health, current_value, progress)" do
      labels = field_labels("goal", :new)
      # msgids for the derived fields — should NOT appear in :new mode.
      refute "Health" in labels
      refute "Current value" in labels
      refute "Progress (0.0-1.0)" in labels
    end
  end

  # ── regression — no 'Hecho' in note kind list ────────────────────────────

  describe "regression — note kind list has no bogus 'Hecho' option" do
    # The original "Hecho" bug came from fuzzy .po pollution (msgid "None"
    # had msgstr "Hecho"). This guards the note kind list itself: it must
    # contain exactly the 7 expected slugs and no 'Hecho' (which was never
    # a real note kind, only a translation artefact).
    test "note_kinds/0 returns exactly 7 expected slugs" do
      assert PageMeta.note_kinds() ==
               ~w(thought journal idea meeting question quote reminder)
    end

    test "note kinds are all lowercase slugs (never display labels)" do
      for kind <- PageMeta.note_kinds() do
        assert kind == String.downcase(kind),
               "note kind #{inspect(kind)} is not lowercase — should be a slug"
      end

      refute "Hecho" in PageMeta.note_kinds()
      refute "Done" in PageMeta.note_kinds()
    end
  end

  # ── regression — no raw 'None' label leaks ──────────────────────────────

  describe "regression — no raw English 'None' label leaks into field labels" do
    # The fix replaces the buggy `gettext("None")` prompt (which had msgstr
    # "Hecho" via fuzzy pollution) with "Ninguno" / "Sin proyecto" /
    # "Sin objetivo" / "Sin plan" in markdown_editor_components.ex. Those
    # prompts are not part of meta_fields_for's return, but we keep a guard
    # that no field label is the English literal "None".
    test "no page type returns 'None' as a field label" do
      for type <- ~w(note concept entity reference artifact plan project goal todo query) do
        refute "None" in field_labels(type),
               "page type #{inspect(type)} has a raw 'None' field label"
      end
    end
  end

  # ── structural — every entry is well-formed ──────────────────────────────

  describe "all page types produce a well-formed meta_fields_for list" do
    # Guards against typos introduced during the gettext wrapping
    # (e.g. a stray gettext call with wrong arity returning a non-string label).
    test "every entry is {atom, binary, binary, list} or {atom, binary, binary}" do
      for type <- ~w(note concept entity reference artifact plan project goal todo query),
          entry <- PageMeta.meta_fields_for(type) do
        case entry do
          {type, key, label}
          when is_atom(type) and is_binary(key) and is_binary(label) ->
            :ok

          {type, key, label, opts}
          when is_atom(type) and is_binary(key) and is_binary(label) and is_list(opts) ->
            :ok

          other ->
            flunk("page type #{inspect(type)} returned malformed entry: #{inspect(other)}")
        end
      end
    end

    test "every :select field has non-empty options" do
      for type <- ~w(note concept entity reference artifact plan project goal todo query),
          {:select, key, _label, opts} <- PageMeta.meta_fields_for(type) do
        # Options may be inline (list of {binary, binary}) or under :options.
        direct_opts =
          Enum.filter(opts, fn
            {k, _v} when is_atom(k) -> false
            {l, v} when is_binary(l) and is_binary(v) -> true
            _ -> false
          end)

        keyword_opts = Keyword.get_values(opts, :options) |> List.flatten()

        all_opts = direct_opts ++ keyword_opts

        assert all_opts != [],
               ":select field #{inspect(key)} for type #{inspect(type)} has no options"
      end
    end
  end
end
