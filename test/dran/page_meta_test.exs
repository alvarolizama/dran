defmodule Dran.PageMetaTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset, only: [traverse_errors: 2]

  alias Dran.Knowledge.PageMeta

  defp errors_on(changeset) do
    traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # Replaces the previous kind-validation coverage: the page model has no
  # sub-type vocabulary any more, so what used to be asserted through `kind`
  # (a meta field that is accepted for some types and rejected for others)
  # is asserted through the fields that DO exist — `props` for every type and
  # the type-specific text/date fields.
  describe "changeset/3 with props" do
    test "accepts a valid props map" do
      attrs = %{"props" => %{"role" => "sales", "tier" => "vip"}}
      cs = PageMeta.changeset(%PageMeta{}, attrs, "entity")

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :props) == %{"role" => "sales", "tier" => "vip"}
    end

    test "accepts empty props map" do
      attrs = %{"props" => %{}}
      cs = PageMeta.changeset(%PageMeta{}, attrs, "note")

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :props) == %{}
    end

    test "accepts nested values inside props" do
      attrs = %{
        "props" => %{"contact" => %{"email" => "a@b.c", "phone" => "123"}, "tags" => ["a", "b"]}
      }

      cs = PageMeta.changeset(%PageMeta{}, attrs, "entity")

      assert cs.valid?
      props = Ecto.Changeset.get_change(cs, :props)
      assert props["contact"]["email"] == "a@b.c"
      assert props["tags"] == ["a", "b"]
    end

    test "rejects non-map props" do
      attrs = %{"props" => "not-a-map"}
      cs = PageMeta.changeset(%PageMeta{}, attrs, "note")

      refute cs.valid?
      assert %{props: [_ | _]} = errors_on(cs)
    end

    test "rejects list props" do
      attrs = %{"props" => ["a", "b"]}
      cs = PageMeta.changeset(%PageMeta{}, attrs, "note")

      refute cs.valid?
    end

    test "props are optional — changeset valid without them" do
      attrs = %{"location" => "CDMX"}
      cs = PageMeta.changeset(%PageMeta{}, attrs, "entity")

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :props) == nil
      assert Ecto.Changeset.get_change(cs, :location) == "CDMX"
    end

    test "props do not interfere with type-specific meta fields" do
      attrs = %{"source_url" => "https://example.com", "props" => %{"role" => "sales"}}
      cs = PageMeta.changeset(%PageMeta{}, attrs, "reference")

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :source_url) == "https://example.com"
      assert Ecto.Changeset.get_change(cs, :props) == %{"role" => "sales"}
    end

    test "props survive across all page types" do
      for type <- ~w(note concept entity reference) do
        attrs = %{"props" => %{"custom" => "value"}}
        cs = PageMeta.changeset(%PageMeta{}, attrs, type)

        assert cs.valid?, "props rejected for type #{type}"
        assert Ecto.Changeset.get_change(cs, :props) == %{"custom" => "value"}
      end
    end
  end

  describe "meta_fields_for/1 with props" do
    test "every page type includes a props field" do
      for type <- ~w(note concept entity reference) do
        fields = PageMeta.meta_fields_for(type)

        assert Enum.any?(fields, fn
                 {:props, "props", _label} -> true
                 _ -> false
               end),
               "type #{type} missing :props field"
      end
    end

    test "props field label is present and points to the props key" do
      fields = PageMeta.meta_fields_for("entity")

      assert Enum.any?(fields, fn
               {:props, "props", _label} -> true
               _ -> false
             end)
    end
  end

  describe "changeset/3 with the removed kind vocabulary" do
    # Replaces "accepts kind project for note": `kind` is no longer part of the
    # schema, so a legacy `kind` in the attrs is dropped by cast instead of
    # validated or persisted.
    test "a legacy kind attr is dropped — kind is not in the embedded schema" do
      cs = PageMeta.changeset(%PageMeta{}, %{"kind" => "project", "date" => "2026-01-01"}, "note")

      assert cs.valid?
      refute Map.has_key?(cs.changes, :kind)
      refute Ecto.Changeset.get_change(cs, :kind)
      assert Ecto.Changeset.get_change(cs, :date) == ~D[2026-01-01]
    end

    test "no page type exposes a kind meta field" do
      for type <- ~w(note concept entity reference) do
        keys =
          Enum.map(PageMeta.meta_fields_for(type), fn
            {_type, key, _label} -> key
            {_type, key, _label, _opts} -> key
          end)

        refute "kind" in keys, "type #{type} still exposes a kind meta field"
      end
    end
  end
end
