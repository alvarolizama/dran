# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Creates the default context from environment variables (or defaults).

alias Dran.Repo
alias Dran.Brain.Context

context_slug = Dran.Auth.default_context_slug()
context_name = Dran.Auth.default_context_name()

case Repo.get_by(Context, slug: context_slug) do
  nil ->
    Repo.insert!(%Context{name: context_name, slug: context_slug})
    IO.puts("Created context: #{context_name} (#{context_slug})")

  existing ->
    IO.puts("Context already exists: #{existing.name} (#{existing.slug})")
end
