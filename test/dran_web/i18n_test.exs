defmodule DranWeb.I18nTest do
  @moduledoc """
  Guards for the app's internationalization contract:

    * **English is the default language.** The `msgid`s in the code are English
      and the app falls back to them, so a missing translation shows English
      rather than an empty string.
    * **Spanish is the secondary language**, with a *complete* catalog — every
      msgid the extractor finds must have a Spanish translation. A half-filled
      catalog is the failure mode this file exists to catch.

  No DB: pure Gettext plus PO/POT file parsing.
  """
  use ExUnit.Case, async: false

  alias DranWeb.Gettext

  @es_po Path.join([File.cwd!(), "priv", "gettext", "es", "LC_MESSAGES", "default.po"])
  @pot Path.join([File.cwd!(), "priv", "gettext", "default.pot"])
  @errors_es_po Path.join([File.cwd!(), "priv", "gettext", "es", "LC_MESSAGES", "errors.po"])
  @errors_pot Path.join([File.cwd!(), "priv", "gettext", "errors.pot"])

  # ── default language ──────────────────────────────────────────────────────

  describe "default language" do
    test "the app default is English" do
      assert Gettext.app_default_locale() == "en"
    end

    test "English is the first (preferred) supported locale" do
      assert Gettext.supported_locales() == ~w(en es)
    end

    test "an unset locale resolves to English" do
      assert Gettext.resolve_locale([]) == "en"
      assert Gettext.resolve_locale([nil, "fr"]) == "en"
    end
  end

  # ── locale normalization ─────────────────────────────────────────────────

  describe "normalize_locale/1" do
    test "maps region/format variants onto the base language" do
      assert Gettext.normalize_locale("es-MX") == "es"
      assert Gettext.normalize_locale("es_ES") == "es"
      assert Gettext.normalize_locale("EN-us") == "en"
      assert Gettext.normalize_locale("ES") == "es"
    end

    test "returns nil for unsupported or blank values" do
      assert Gettext.normalize_locale("fr") == nil
      assert Gettext.normalize_locale("") == nil
      assert Gettext.normalize_locale(nil) == nil
      assert Gettext.normalize_locale(:es) == nil
    end
  end

  # ── resolution order ─────────────────────────────────────────────────────

  describe "resolve_locale/1" do
    test "takes the first usable candidate" do
      assert Gettext.resolve_locale([nil, "fr", "es", "en"]) == "es"
      assert Gettext.resolve_locale(["es-AR"]) == "es"
    end

    test "falls back to English when no candidate matches" do
      assert Gettext.resolve_locale([nil, "de", "pt"]) == "en"
    end
  end

  # ── Accept-Language ──────────────────────────────────────────────────────

  describe "from_accept_language/1" do
    test "picks the first supported language in preference order" do
      assert Gettext.from_accept_language("fr-FR,fr;q=0.9,es;q=0.8,en;q=0.7") == "es"
      assert Gettext.from_accept_language("en-US,en;q=0.9") == "en"
    end

    test "returns nil when nothing is supported or the header is missing" do
      assert Gettext.from_accept_language("de,fr;q=0.5") == nil
      assert Gettext.from_accept_language(nil) == nil
    end
  end

  # ── Spanish catalog completeness ─────────────────────────────────────────

  describe "the Spanish catalog is complete" do
    test "every extracted msgid has a non-empty Spanish translation" do
      pot = catalog(@pot)
      es = catalog(@es_po)

      assert map_size(pot) > 0

      missing =
        pot
        |> Enum.filter(fn {msgid, _} -> String.trim(Map.get(es, msgid, "")) == "" end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      assert missing == [], """
      #{length(missing)} msgid(s) have no Spanish translation in
      priv/gettext/es/LC_MESSAGES/default.po. Run `mix gettext.extract --merge`
      and add them (scripts/fill_es_gettext.py carries the curated dictionary):

      #{Enum.map_join(missing, "\n", &"  * #{&1}")}
      """

      # Sanity: the two catalogs describe the same set of messages.
      assert Map.keys(es) -- Map.keys(pot) == []
    end

    test "the Spanish catalog has no fuzzy entries" do
      # A fuzzy translation is ignored by Gettext, so it silently falls back to
      # the English msgid — dead weight that looks like a translation.
      refute File.read!(@es_po) =~ ~r/^#,.*fuzzy/m, "the Spanish catalog still has fuzzy entries"
    end

    test "the Spanish validation-message catalog is complete too" do
      # The `errors` domain holds Ecto's changeset messages. If one is missing,
      # the form error comes out in English inside an otherwise Spanish page.
      pot = catalog(@errors_pot)
      es = catalog(@errors_es_po)

      assert map_size(pot) > 0

      missing =
        pot
        |> Enum.filter(fn {msgid, _} -> String.trim(Map.get(es, msgid, "")) == "" end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      assert missing == [], "missing Spanish validation messages: #{inspect(missing)}"
    end
  end

  # ── PO/POT parsing ───────────────────────────────────────────────────────

  # %{msgid => msgstr}; for plural entries the value is msgstr[0], which is
  # enough to prove the entry is translated rather than empty.
  defp catalog(path) do
    path
    |> File.read!()
    |> String.split(~r/\n\n+/)
    |> Enum.reduce(%{}, fn block, acc ->
      case entry_of(block) do
        {msgid, msgstr} when msgid != "" -> Map.put(acc, msgid, msgstr)
        _ -> acc
      end
    end)
  end

  defp entry_of(block) do
    lines = String.split(block, "\n")

    {msgid, _} = collect(lines, "msgid ")
    {msgstr, _} = collect(lines, "msgstr ")

    plural =
      lines
      |> Enum.drop_while(&(not String.starts_with?(&1, "msgstr[")))
      |> List.first()

    {msgid, msgstr || plural || ""}
  end

  # A PO string may be split across lines: the keyword line plus any following
  # line that starts with a quote. Returns {joined, rest}.
  defp collect(lines, keyword) do
    case Enum.drop_while(lines, &(not String.starts_with?(&1, keyword))) do
      [] ->
        {nil, []}

      [first | rest] ->
        {continuations, tail} = Enum.split_while(rest, &String.starts_with?(&1, "\""))

        joined =
          [String.replace_prefix(first, keyword, "") | continuations]
          |> Enum.join("")

        {decode(joined), tail}
    end
  end

  # Turns `"foo" "bar"` into `foo bar`.
  defp decode(raw) do
    raw
    |> then(&Regex.scan(~r/"((?:[^"\\]|\\.)*)"/, &1))
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.join("")
  end
end
