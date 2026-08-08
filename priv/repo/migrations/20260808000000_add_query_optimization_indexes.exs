defmodule Dran.Repo.Migrations.AddQueryOptimizationIndexes do
  use Ecto.Migration

  @doc """
  Indexes for the hottest query patterns in the second-brain.

  Cover queries:
    1. `list_pages(context_id:, type:, archived:)` — page-type lists
       (todos, goals, notes, ...) filter on all three columns together.
    2. `list_tags/1` — tags for a context, archived-only.
    3. `graph_data/2` + `top_connected_ids/2` — the global graph joins
       relations → pages and filters `page_type not in exclude_types`,
       so `(context_id, page_type)` makes the join index-only.
    4. `graph_type_counts/2` — GROUP BY page_type per context.
    5. `get_page_version/2` — exact page_id + version lookup (versions
       panel) — the two separate indexes can't serve this composite.
    6. `list_log/1` — context scoped, ordered by inserted_at desc.
  """

  def up do
    # 1 + 2 + 4: pages filtered by type+archived within a context.
    create index(:pages, [:context_id, :page_type, :archived], name: :pages_ctx_type_archived_idx)

    # 3: pages by context+type for graph joins / counts.
    create index(:pages, [:context_id, :page_type], name: :pages_ctx_type_idx)

    # 5: exact version lookup per page.
    create unique_index(:page_versions, [:page_id, :version],
             name: :page_versions_page_version_uidx
           )

    # 6: activity log — context scoped, time-ordered.
    create index(:brain_log, [:context_id, :inserted_at], name: :brain_log_ctx_inserted_at_idx)
  end

  def down do
    drop index(:pages, [:context_id, :page_type, :archived], name: :pages_ctx_type_archived_idx)

    drop index(:pages, [:context_id, :page_type], name: :pages_ctx_type_idx)

    drop index(:page_versions, [:page_id, :version], name: :page_versions_page_version_uidx)

    drop index(:brain_log, [:context_id, :inserted_at], name: :brain_log_ctx_inserted_at_idx)
  end
end
