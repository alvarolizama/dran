defmodule Dran.SlugTest do
  use ExUnit.Case, async: true

  alias Dran.Slug

  describe "slugify/1 — unicode and ASCII normalization" do
    test "strips accents and lowercases" do
      assert Slug.slugify("Meditación Tántrica") == "meditacion-tantrica"
    end

    test "drops punctuation, keeps alphanumerics, joins with hyphens" do
      assert Slug.slugify("Elixir & Phoenix 1.8!") == "elixir-phoenix-1-8"
    end
  end

  describe "slugify/1 — empty / degenerate inputs fall back to untitled" do
    test "empty string" do
      assert Slug.slugify("") == "untitled"
    end

    test "whitespace only" do
      assert Slug.slugify("   ") == "untitled"
    end

    test "only hyphens / separators" do
      assert Slug.slugify("---") == "untitled"
    end

    test "non-binary input returns untitled" do
      assert Slug.slugify(nil) == "untitled"
      assert Slug.slugify(123) == "untitled"
    end
  end
end
