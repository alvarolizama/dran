defmodule Dran.PageMetaGettextTest do
  # Verifies that all field labels returned by meta_fields_for/1,2 go through
  # gettext.
  #
  # Strategy: prove labels are routed through gettext by checking that the
  # msgid appears in priv/gettext/default.pot — the extractor only writes
  # msgids it found as `gettext("...")` calls in source code. We do NOT assert
  # on specific Spanish strings.
  #
  # The previous select-option coverage (kind labels/values per type) is gone
  # with the vocabulary: no page type renders a select any more, so there are
  # no option labels or DB slugs to check. The replacement coverage is the
  # field-label routing below plus the structural guards — both now run over
  # the four surviving types.
  #
  # We use ExUnit.Case (no DB) — same style as page_meta_test.exs.
  use ExUnit.Case, async: false

  alias Dran.Knowledge.PageMeta

  # meta_fields_for/1,2 resolves gettext at call time against the CURRENT
  # process locale. English is the default, so we pin the locale explicitly.
  # We assert against the msgids in default.pot (English source strings), so
  # each assertion helper pins the process locale to "en" while collecting.
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

  # Collect the field labels (3rd tuple element) for a page type.
  defp field_labels(type, mode \\ :edit) do
    with_en_locale(fn -> raw_field_labels(type, mode) end)
  end

  # Same, but WITHOUT pinning the locale — used to prove runtime localization.
  defp raw_field_labels(type, mode \\ :edit) do
    type
    |> PageMeta.meta_fields_for(mode)
    |> Enum.map(fn
      {_type, _key, label, _opts} -> label
      {_type, _key, label} -> label
    end)
  end

  # ── field labels are routed through gettext ──────────────────────────────

  describe "field labels (3rd tuple element) are routed through gettext" do
    test "every field label across all page types is in default.pot" do
      for type <- ~w(note concept entity reference),
          label <- field_labels(type) do
        assert pot_has?(label),
               "field label #{inspect(label)} for type #{inspect(type)} not in default.pot — not gettext'd"
      end
    end

    test "labels are localized at runtime (es differs from the msgid for known fields)" do
      # Routes through Gettext.gettext/2 — the note's "Date" label carries a
      # Spanish msgstr ("Fecha"), so the es render must not equal the msgid.
      Gettext.put_locale(DranWeb.Gettext, "en")
      labels_en = raw_field_labels("note")
      Gettext.put_locale(DranWeb.Gettext, "es")
      labels_es = raw_field_labels("note")

      assert "Date" in labels_en
      refute "Date" in labels_es, "the note Date label is not localized"
      assert "Fecha" in labels_es
    end
  end

  # ── no kind field anywhere ───────────────────────────────────────────────

  describe "no page type exposes kind fields or options" do
    # Replaces the per-type "kind values are raw slugs" coverage: the kind
    # vocabulary is gone from the model, so the proof is that no field key is
    # "kind" and no select field survives to carry option labels.
    test "no page type has a kind key among its meta fields" do
      for type <- ~w(note concept entity reference) do
        keys =
          Enum.map(PageMeta.meta_fields_for(type), fn
            {_type, key, _label} -> key
            {_type, key, _label, _opts} -> key
          end)

        refute "kind" in keys, "type #{type} still exposes a kind meta field"
      end
    end

    test "no page type renders a :select meta field" do
      for type <- ~w(note concept entity reference) do
        refute Enum.any?(PageMeta.meta_fields_for(type), fn
                 {:select, _key, _label, _opts} -> true
                 {:select, _key, _label} -> true
                 _ -> false
               end),
               "type #{type} still renders a :select meta field"
      end
    end
  end

  # ── regression — no raw 'None' label leaks ──────────────────────────────

  describe "regression — no raw English 'None' label leaks into field labels" do
    # The fix replaces the buggy `gettext("None")` prompt (which had msgstr
    # "Hecho" via fuzzy pollution) with "Ninguno" in the UI. Those prompts are
    # not part of meta_fields_for's return, but we keep a guard that no field
    # label is the English literal "None".
    test "no page type returns 'None' as a field label" do
      for type <- ~w(note concept entity reference) do
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
      for type <- ~w(note concept entity reference),
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

    test "every page type ends with the props field" do
      with_en_locale(fn ->
        for type <- ~w(note concept entity reference) do
          assert List.last(PageMeta.meta_fields_for(type)) ==
                   {:props, "props", "Custom properties"},
                 "type #{type} does not end with the props field"
        end
      end)
    end
  end
end
