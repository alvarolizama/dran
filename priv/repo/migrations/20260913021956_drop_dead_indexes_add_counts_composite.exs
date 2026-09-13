defmodule Dran.Repo.Migrations.DropDeadIndexesAddCountsComposite do
  use Ecto.Migration

  @doc """
  Dead index cleanup (verified against pg_stat_user_indexes.idx_scan) plus
  the one composite the sidebar count path was missing.

  DROPPED — features removed (kanban/todo/plans) or superseded:
    - knowledge_pages_meta_kanban_status_idx  (kanban removed; 9 legacy scans)
    - knowledge_pages_meta_assignee_idx       (assignee removed; 0 scans)
    - knowledge_pages_meta_plan_slug_idx      (plan type removed; 0 scans)
    - knowledge_pages_meta_project_slug_idx   (project filter removed; 0 scans)
    - knowledge_pages_workspace_id_slug_idx   (NON-unique duplicate of the
      unique knowledge_pages_workspace_id_slug_index; 0 scans)
    - knowledge_pages_type_idx                (prefix-redundant: every query
      filters workspace first; covered by ctx_type / ctx_type_archived)
    - relations_source_idx / relations_target_idx (prefix-redundant with
      the (id, type) composites)
    - worker_steps_session_id_index           (prefix of
      worker_steps_session_id_step_number_index)
    - brain_log_workspace_id_index            (prefix of
      brain_log_ctx_inserted_at_idx)
    - community_summaries_* (3)               (leftovers of the
      community→cluster rename; the cluster_* twins are the live ones,
      5417 scans vs 0-17)

  ADDED:
    - knowledge_pages_ws_archived_type_idx (workspace_id, archived,
      page_type) — serves Knowledge.stats/1 by_type (group_by page_type
      where workspace + not archived), the sidebar count path on every
      page render.
  """
  def up do
    drop_if_exists index(:knowledge_pages, [:meta_kanban_status],
                     name: :knowledge_pages_meta_kanban_status_idx,
                     where: "(meta ->> 'kanban_status') IS NOT NULL"
                   )

    drop_if_exists index(:knowledge_pages, [:meta_assignee],
                     name: :knowledge_pages_meta_assignee_idx,
                     where: "(meta ->> 'assignee') IS NOT NULL"
                   )

    drop_if_exists index(:knowledge_pages, [:meta_plan_slug],
                     name: :knowledge_pages_meta_plan_slug_idx,
                     where: "(meta ->> 'plan_slug') IS NOT NULL"
                   )

    drop_if_exists index(:knowledge_pages, [:meta_project_slug],
                     name: :knowledge_pages_meta_project_slug_idx,
                     where: "(meta ->> 'project_slug') IS NOT NULL"
                   )

    drop_if_exists index(:knowledge_pages, [:workspace_id, :slug],
                     name: :knowledge_pages_workspace_id_slug_idx
                   )

    drop_if_exists index(:knowledge_pages, [:page_type], name: :knowledge_pages_type_idx)

    drop_if_exists index(:relations, [:source_id], name: :relations_source_idx)
    drop_if_exists index(:relations, [:target_id], name: :relations_target_idx)

    drop_if_exists index(:worker_steps, [:session_id], name: :worker_steps_session_id_index)

    drop_if_exists index(:brain_log, [:workspace_id], name: :brain_log_workspace_id_index)

    execute("DROP INDEX IF EXISTS community_summaries_pkey_boundary_never_matches")
    execute("DROP INDEX IF EXISTS community_summaries_workspace_id_index")
    execute("DROP INDEX IF EXISTS community_summaries_workspace_id_community_id_index")
    # community_summaries_pkey is the table's PRIMARY KEY under its old name;
    # it cannot be dropped while the constraint exists. Renaming the index
    # keeps the constraint but fixes the misleading name.
    execute("ALTER INDEX IF EXISTS community_summaries_pkey RENAME TO cluster_summaries_pkey")
    # Same for the FK's backing index name (constraint itself is fine).
    execute(
      "ALTER INDEX IF EXISTS cluster_summaries_workspace_id_cluster_id_index RENAME TO cluster_summaries_ws_cluster_uidx"
    )

    create_if_not_exists index(:knowledge_pages, [:workspace_id, :archived, :page_type],
                           name: :knowledge_pages_ws_archived_type_idx
                         )
  end

  def down do
    drop_if_exists index(:knowledge_pages, [:workspace_id, :archived, :page_type],
                     name: :knowledge_pages_ws_archived_type_idx
                   )

    execute(
      "ALTER INDEX IF EXISTS cluster_summaries_ws_cluster_uidx RENAME TO cluster_summaries_workspace_id_cluster_id_index"
    )

    execute("ALTER INDEX IF EXISTS cluster_summaries_pkey RENAME TO community_summaries_pkey")

    execute(
      "CREATE INDEX IF NOT EXISTS community_summaries_workspace_id_index ON cluster_summaries (workspace_id)"
    )

    execute(
      "CREATE UNIQUE INDEX IF NOT EXISTS community_summaries_workspace_id_community_id_index ON cluster_summaries (workspace_id, cluster_id)"
    )

    create_if_not_exists index(:brain_log, [:workspace_id], name: :brain_log_workspace_id_index)
    create_if_not_exists index(:worker_steps, [:session_id], name: :worker_steps_session_id_index)
    create_if_not_exists index(:relations, [:target_id], name: :relations_target_idx)
    create_if_not_exists index(:relations, [:source_id], name: :relations_source_idx)
    create_if_not_exists index(:knowledge_pages, [:page_type], name: :knowledge_pages_type_idx)

    create_if_not_exists index(:knowledge_pages, [:workspace_id, :slug],
                           name: :knowledge_pages_workspace_id_slug_idx
                         )

    create_if_not_exists index(:knowledge_pages, [:meta_project_slug],
                           name: :knowledge_pages_meta_project_slug_idx,
                           where: "(meta ->> 'project_slug') IS NOT NULL"
                         )

    create_if_not_exists index(:knowledge_pages, [:meta_plan_slug],
                           name: :knowledge_pages_meta_plan_slug_idx,
                           where: "(meta ->> 'plan_slug') IS NOT NULL"
                         )

    create_if_not_exists index(:knowledge_pages, [:meta_assignee],
                           name: :knowledge_pages_meta_assignee_idx,
                           where: "(meta ->> 'assignee') IS NOT NULL"
                         )

    create_if_not_exists index(:knowledge_pages, [:meta_kanban_status],
                           name: :knowledge_pages_meta_kanban_status_idx,
                           where: "(meta ->> 'kanban_status') IS NOT NULL"
                         )
  end
end
