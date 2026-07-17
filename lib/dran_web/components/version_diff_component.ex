defmodule DranWeb.VersionDiffComponent do
  @moduledoc """
  Function component that renders a line-by-line diff between two page versions
  using `List.myers_difference/2`.
  """

  use Phoenix.Component
  import DranWeb.CoreComponents, only: [icon: 1]

  attr :old_version, :map, default: nil, doc: "The older PageVersion struct"
  attr :new_version, :map, default: nil, doc: "The newer PageVersion or Page struct"

  def diff(assigns) do
    old_lines = body_to_lines(assigns[:old_version])
    new_lines = body_to_lines(assigns[:new_version])

    diff_lines =
      List.myers_difference(old_lines, new_lines)
      |> Enum.flat_map(fn
        {:eq, lines} -> Enum.map(lines, &{:eq, &1})
        {:ins, lines} -> Enum.map(lines, &{:ins, &1})
        {:del, lines} -> Enum.map(lines, &{:del, &1})
      end)

    assigns = assign(assigns, :diff_lines, diff_lines)

    ~H"""
    <div class="rounded-lg border border-base-300 overflow-hidden">
      <div class="bg-base-200 px-4 py-2 border-b border-base-300 flex items-center justify-between">
        <div>
          <h3 class="text-sm font-semibold">Version Diff</h3>
          <p class="text-xs text-base-content/60">
            Comparing v{@old_version.version} with v{@new_version.version}
          </p>
        </div>
        <button phx-click="clear_compare" class="btn btn-ghost btn-xs">
          <.icon name="hero-x-mark" class="size-3" /> Close
        </button>
      </div>
      <div class="font-mono text-xs overflow-x-auto max-h-[60vh] overflow-y-auto">
        <div :for={{type, line} <- @diff_lines} class={diff_line_class(type)}>
          <span class="inline-block w-6 shrink-0 text-center select-none">
            {diff_prefix(type)}
          </span>
          <span class="whitespace-pre">{line}</span>
        </div>
      </div>
    </div>
    """
  end

  defp body_to_lines(nil), do: []
  defp body_to_lines(%{body: nil}), do: []
  defp body_to_lines(%{body: ""}), do: []
  defp body_to_lines(%{body: body}) when is_binary(body), do: String.split(body, "\n")

  defp diff_line_class(:ins), do: "bg-green-100 text-green-800 px-2 py-0.5 flex"
  defp diff_line_class(:del), do: "bg-red-100 text-red-800 px-2 py-0.5 flex"
  defp diff_line_class(:eq), do: "px-2 py-0.5 flex"

  defp diff_prefix(:ins), do: "+"
  defp diff_prefix(:del), do: "-"
  defp diff_prefix(:eq), do: " "
end
