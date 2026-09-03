defmodule Dran.Repo.Migrations.RenameDescriptionsToSummary do
  @moduledoc """
  Unify the one-liner field name across resources to `summary`.

  Goals and collections used `description`; pages and tasks already use
  `summary` (pages have the whole AI pipeline wired to it: embeddings,
  rerank, GraphRAG). One name, one meaning everywhere.
  """

  use Ecto.Migration

  def up do
    rename table(:goals), :description, to: :summary
    rename table(:collections), :description, to: :summary
  end

  def down do
    rename table(:goals), :summary, to: :description
    rename table(:collections), :summary, to: :description
  end
end
