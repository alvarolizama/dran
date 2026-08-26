defmodule DranWeb.PropsEditorTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DranWeb.MarkdownEditorComponents

  defp render_props_editor(assigns) do
    assigns = Map.new(assigns)

    render_component(&MarkdownEditorComponents.props_editor/1, assigns)
  end

  test "renders one row per key/value pair from a map value" do
    html = render_props_editor(id: "p1", name: "page[meta][props]", value: %{"role" => "sales"})

    assert html =~ ~s(data-prop-row)
    assert html =~ ~s(value="role")
    assert html =~ ~s(value="sales")
  end

  test "hidden input carries the canonical JSON object" do
    html =
      render_props_editor(id: "p2", name: "page[meta][props]", value: %{"role" => "sales"})

    assert html =~
             ~s(<input type="hidden" name="page[meta][props]" value="{&quot;role&quot;:&quot;sales&quot;}")
  end

  test "renders rows from a JSON string value (live form params)" do
    html =
      render_props_editor(
        id: "p3",
        name: "page[meta][props]",
        value: ~s({"tier": "vip"})
      )

    assert html =~ ~s(value="tier")
    assert html =~ ~s(value="vip")
    assert html =~ ~s(data-props-value)
  end

  test "hidden input is empty and no rows render when value is empty" do
    html = render_props_editor(id: "p4", name: "page[meta][props]", value: "")

    refute html =~ ~s(data-prop-key)
    assert html =~ ~s(<input type="hidden" name="page[meta][props]" value="")
  end

  test "invalid JSON string value renders no rows and empty hidden input" do
    html = render_props_editor(id: "p5", name: "page[meta][props]", value: "not-json{")

    refute html =~ ~s(data-prop-key)
    assert html =~ ~s(<input type="hidden" name="page[meta][props]" value="")
  end

  test "non-string values are JSON-encoded for display but kept typed in the hidden input" do
    html =
      render_props_editor(id: "p6", name: "page[meta][props]", value: %{"count" => 3})

    assert html =~ ~s(value="count")
    assert html =~ ~s(value="3")
    # hidden keeps the original typed value (3, not "3")
    assert html =~ ~s(value="{&quot;count&quot;:3}")
  end

  test "renders add button and mounts the colocated PropsEditor hook" do
    html = render_props_editor(id: "p7", name: "page[meta][props]", value: %{})

    assert html =~ ~s(data-prop-add)
    assert html =~ ~s(phx-hook="DranWeb.MarkdownEditorComponents.PropsEditor")
  end
end
