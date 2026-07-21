defmodule DranWeb.TagInputTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Phoenix.Component

  alias DranWeb.MarkdownEditorComponents

  defp render_tag_input(assigns) do
    assigns = Map.new(assigns)

    render_component(&MarkdownEditorComponents.tag_input/1, assigns)
  end

  test "renders one chip per tag from a comma-separated value" do
    html = render_tag_input(id: "t1", name: "page[tags]", value: "uno,dos")

    assert html =~ ~s(data-tag-chip="uno")
    assert html =~ ~s(data-tag-chip="dos")
  end

  test "renders chips from a list value" do
    html = render_tag_input(id: "t2", name: "page[tags]", value: ["alpha", "beta", "gamma"])

    assert html =~ ~s(data-tag-chip="alpha")
    assert html =~ ~s(data-tag-chip="beta")
    assert html =~ ~s(data-tag-chip="gamma")
  end

  test "hidden input carries the canonical comma-separated value" do
    html = render_tag_input(id: "t3", name: "page[tags]", value: "uno, dos ,tres")

    assert html =~ ~s(<input type="hidden" name="page[tags]" value="uno,dos,tres")
  end

  test "hidden input is empty when there are no tags" do
    html = render_tag_input(id: "t4", name: "page[tags]", value: "")

    assert html =~ ~s(<input type="hidden" name="page[tags]" value="")
  end

  test "datalist renders suggestions for autocomplete" do
    html =
      render_tag_input(
        id: "t5",
        name: "page[tags]",
        value: "",
        suggestions: ["elixir", "phoenix"]
      )

    assert html =~ ~s(<datalist id="t5-suggestions">)
    assert html =~ ~s(<option value="elixir">)
    assert html =~ ~s(<option value="phoenix">)
  end

  test "mounts the colocated TagInput hook" do
    html = render_tag_input(id: "t6", name: "page[tags]", value: "")

    # Colocated hooks render with the fully-qualified module name when the
    # component is rendered outside a LiveView (test context).
    assert html =~ ~s(phx-hook="DranWeb.MarkdownEditorComponents.TagInput")
  end
end
