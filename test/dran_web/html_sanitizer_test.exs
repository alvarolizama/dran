defmodule DranWeb.HTMLSanitizerTest do
  use ExUnit.Case, async: true

  alias DranWeb.HTMLSanitizer

  describe "sanitize/1" do
    test "preserves allowed <b> tags from ts_headline" do
      assert {:safe, "hello <b>world</b> rest"} =
               HTMLSanitizer.sanitize("hello <b>world</b> rest")
    end

    test "preserves all allowed tags" do
      for tag <- ~w(b strong em i mark) do
        input = "prefix <#{tag}>highlighted</#{tag}> suffix"
        expected = "prefix <#{tag}>highlighted</#{tag}> suffix"
        assert {:safe, ^expected} = HTMLSanitizer.sanitize(input)
      end
    end

    test "escapes <script> tags (XSS protection)" do
      result = HTMLSanitizer.sanitize("<script>alert(1)</script>")
      assert {:safe, safe_html} = result
      refute String.contains?(safe_html, "<script")
      assert String.contains?(safe_html, "&lt;script&gt;")
    end

    test "escapes <img> tags with onerror handlers" do
      result = HTMLSanitizer.sanitize("<img onerror=alert(1) src=x>")
      assert {:safe, safe_html} = result
      refute String.contains?(safe_html, "<img")
      assert String.contains?(safe_html, "&lt;img")
    end

    test "escapes disallowed tags while preserving <b> highlights" do
      input = "<b>match</b> <script>alert(1)</script> <b>another</b>"
      result = HTMLSanitizer.sanitize(input)
      assert {:safe, safe_html} = result

      # Bold tags preserved
      assert String.contains?(safe_html, "<b>match</b>")
      assert String.contains?(safe_html, "<b>another</b>")
      # Script escaped
      refute String.contains?(safe_html, "<script")
      assert String.contains?(safe_html, "&lt;script&gt;")
    end

    test "strips attributes from allowed tags" do
      # A <b> with an attribute should be escaped, not rendered as a live <b> tag
      result = HTMLSanitizer.sanitize("<b onclick=alert(1)>match</b>")
      assert {:safe, safe_html} = result
      # The tag should be escaped, not rendered as a live HTML tag
      refute String.contains?(safe_html, "<b onclick")
      assert String.contains?(safe_html, "&lt;b")
    end

    test "returns empty safe string for nil" do
      assert {:safe, ""} = HTMLSanitizer.sanitize(nil)
    end

    test "handles empty string" do
      assert {:safe, ""} = HTMLSanitizer.sanitize("")
    end

    test "passes through plain text unchanged" do
      assert {:safe, "just plain text"} = HTMLSanitizer.sanitize("just plain text")
    end

    test "handles malformed tag without closing >" do
      result = HTMLSanitizer.sanitize("<b unclosed text here")
      assert {:safe, safe_html} = result
      refute String.contains?(safe_html, "<b>")
    end

    test "simulates real ts_headline output with XSS in body" do
      # This simulates what ts_headline would produce if the body contains
      # a script tag and a search match
      ts_output = "Some text <b>searchterm</b> <script>alert(1)</script> more"
      result = HTMLSanitizer.sanitize(ts_output)
      assert {:safe, safe_html} = result

      assert String.contains?(safe_html, "<b>searchterm</b>")
      refute String.contains?(safe_html, "<script")
      assert String.contains?(safe_html, "&lt;script&gt;")
    end

    test "case-insensitive matching of allowed tags" do
      assert {:safe, "<b>match</b>"} = HTMLSanitizer.sanitize("<B>match</B>")
    end
  end

  describe "sanitize_to_string/1" do
    test "returns a plain string" do
      assert HTMLSanitizer.sanitize_to_string("hello <b>world</b>") == "hello <b>world</b>"
    end

    test "returns escaped string for XSS" do
      result = HTMLSanitizer.sanitize_to_string("<script>alert(1)</script>")
      refute String.contains?(result, "<script")
      assert String.contains?(result, "&lt;script&gt;")
    end

    test "returns empty string for nil" do
      assert HTMLSanitizer.sanitize_to_string(nil) == ""
    end
  end
end
