defmodule Dran.Brain.PageMetaTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset, only: [traverse_errors: 2]

  alias Dran.Brain.PageMeta

  defp errors_on(changeset) do
    traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "changeset/3 with props" do
    test "accepts a valid props map" do
      attrs = %{"kind" => "person", "props" => %{"role" => "sales", "tier" => "vip"}}
      cs = PageMeta.changeset(%PageMeta{}, attrs, "entity")

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :props) == %{"role" => "sales", "tier" => "vip"}
    end

    test "accepts empty props map" do
      attrs = %{"kind" => "thought", "props" => %{}}
      cs = PageMeta.changeset(%PageMeta{}, attrs, "note")

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :props) == %{}
    end

    test "accepts nested values inside props" do
      attrs = %{
        "kind" => "person",
        "props" => %{"contact" => %{"email" => "a@b.c", "phone" => "123"}, "tags" => ["a", "b"]}
      }

      cs = PageMeta.changeset(%PageMeta{}, attrs, "entity")

      assert cs.valid?
      props = Ecto.Changeset.get_change(cs, :props)
      assert props["contact"]["email"] == "a@b.c"
      assert props["tags"] == ["a", "b"]
    end

    test "rejects non-map props" do
      attrs = %{"kind" => "thought", "props" => "not-a-map"}
      cs = PageMeta.changeset(%PageMeta{}, attrs, "note")

      refute cs.valid?
      assert %{props: [_ | _]} = errors_on(cs)
    end

    test "rejects list props" do
      attrs = %{"kind" => "thought", "props" => ["a", "b"]}
      cs = PageMeta.changeset(%PageMeta{}, attrs, "note")

      refute cs.valid?
    end

    test "props are optional — changeset valid without them" do
      attrs = %{"kind" => "person"}
      cs = PageMeta.changeset(%PageMeta{}, attrs, "entity")

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :props) == nil
    end

    test "props do not interfere with kind validation" do
      attrs = %{"kind" => "invalid-kind", "props" => %{"role" => "sales"}}
      cs = PageMeta.changeset(%PageMeta{}, attrs, "entity")

      refute cs.valid?
      assert %{kind: [_ | _]} = errors_on(cs)
    end

    test "props survive across all page types" do
      for type <- ~w(note concept entity reference plan project goal todo query) do
        attrs = %{"props" => %{"custom" => "value"}}
        cs = PageMeta.changeset(%PageMeta{}, attrs, type)

        assert cs.valid?, "props rejected for type #{type}"
        assert Ecto.Changeset.get_change(cs, :props) == %{"custom" => "value"}
      end
    end
  end

  describe "meta_fields_for/1 with props" do
    test "every page type includes a props field" do
      for type <- ~w(note concept entity reference plan project goal todo query) do
        fields = PageMeta.meta_fields_for(type)

        assert Enum.any?(fields, fn
                 {:props, "props", _label} -> true
                 _ -> false
               end),
               "type #{type} missing :props field"
      end
    end

    test "props field label is Custom properties" do
      fields = PageMeta.meta_fields_for("entity")

      assert {:props, "props", "Custom properties"} in fields
    end
  end
end
