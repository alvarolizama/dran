defmodule Dran.Repo.Migrations.RestructurePageTypesByKind do
  use Ecto.Migration

  @moduledoc """
  Splits the monolithic `note` type into semantic types by kind.

  note + kind IN (idea, question)                 → idea
  note + kind IN (plan, project)                  → project
  note + kind IN (quote, summary)                 → knowledge
  note + kind IN (code, debug, recipe, template,
                   technical)                      → technical
  concept + kind IN (pattern, method, technique)  → technical
  note/concept without those kinds                → unchanged (kinds: nil —
                                                     free types, legacy
                                                     meta.kind survives as
                                                     inert data)

  Reversible: down maps the new types back to note/concept by kind.
  """

  @up [
    {"idea", ~w(idea question), "note"},
    {"project", ~w(plan project), "note"},
    {"knowledge", ~w(quote summary), "note"},
    {"technical", ~w(code debug recipe template technical), "note"},
    {"technical", ~w(pattern method technique), "concept"}
  ]

  def up do
    for {new_type, kinds, old_type} <- @up do
      execute(
        "UPDATE knowledge_pages SET page_type = '#{new_type}' " <>
          "WHERE page_type = '#{old_type}' AND meta->>'kind' IN (#{kind_list(kinds)})",
        "UPDATE knowledge_pages SET page_type = '#{old_type}' " <>
          "WHERE page_type = '#{new_type}' AND meta->>'kind' IN (#{kind_list(kinds)})"
      )
    end
  end

  def down do
    for {new_type, kinds, old_type} <- Enum.reverse(@up) do
      execute(
        "UPDATE knowledge_pages SET page_type = '#{old_type}' " <>
          "WHERE page_type = '#{new_type}' AND meta->>'kind' IN (#{kind_list(kinds)})",
        "UPDATE knowledge_pages SET page_type = '#{new_type}' " <>
          "WHERE page_type = '#{old_type}' AND meta->>'kind' IN (#{kind_list(kinds)})"
      )
    end
  end

  defp kind_list(kinds) do
    kinds |> Enum.map(&"'#{&1}'") |> Enum.join(", ")
  end
end
