defmodule DranWeb.PageComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.HTML, only: [safe_to_string: 1]

  alias DranWeb.PageComponents

  defp render(body, opts \\ []) do
    body
    |> PageComponents.render_markdown(opts)
    |> safe_to_string()
  end

  describe "render_markdown/2" do
    test "preserves language-* class on fenced code blocks (mermaid hook depends on it)" do
      html = render("```mermaid\nflowchart LR\n  A --> B\n```")

      assert html =~ ~s(<code class="language-mermaid">)
    end

    test "preserves language class for other languages" do
      html = render("```elixir\nIO.puts(\"hola\")\n```")

      assert html =~ ~s(<code class="language-elixir">)
    end

    test "still renders tables and tasklists" do
      html = render("| a | b |\n|---|---|\n| 1 | 2 |\n\n- [ ] todo\n")

      assert html =~ "<table>"
      assert html =~ "<input"
    end
  end
end
