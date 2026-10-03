defmodule Dran.Repo.Migrations.ScopeUniqueIndexesByOwner do
  @moduledoc """
  W4a (contract.md, shaping F30/F31): the slug stops being unique per
  workspace and becomes unique per `(owner, type)`.

  `workspace_id` is constant in the single-instance model, so the old
  `(workspace_id, slug)` indexes made the slug GLOBAL: two accounts could
  never share a name, and the collision was resolved with a random hex
  suffix visible in the URL. With content private by default, a collision
  between two people is the daily case, not the corner (F30).

  The cursor moves to `(dueño, tipo)`:

    * `knowledge_pages` → `(COALESCE(owner_user_id, 0), page_type, slug)`
      (the page's TYPE is `page_type`);
    * `collections` and `reports` → `(COALESCE(owner_user_id, 0), slug)`
      (each is a single type, so the type axis is the table itself).

  ## Why COALESCE (the NULL-owner bucket)

  In a unique index, NULLs are distinct from each other: without folding,
  every system-produced row (owner NULL) would be collision-FREE and two
  system pages with the same slug+type could coexist. `COALESCE(owner_user_id,
  0)` gives every NULL owner one shared bucket (user ids start at 1, so 0 is
  never a real owner), so system content stays unique per type — exactly the
  guarantee the app-level predicate states, and exactly the semantics the
  unique index enforces. `NULLS NOT DISTINCT` (PG 15+) would say the same
  thing; COALESCE is used because it also makes the Ecto `unique_constraint`
  error deterministic across all three tables.

  Reversible: `down` restores the workspace-scoped indexes.
  """

  use Ecto.Migration

  def up do
    drop_if_exists index(:knowledge_pages, [:workspace_id, :slug],
                     name: :knowledge_pages_workspace_id_slug_index
                   )

    drop_if_exists index(:collections, [:workspace_id, :slug],
                     name: :collections_workspace_id_slug_index
                   )

    drop_if_exists index(:reports, [:workspace_id, :slug], name: :reports_workspace_id_slug_index)

    create index(:knowledge_pages, ["COALESCE(owner_user_id, 0)", :page_type, :slug],
             name: :knowledge_pages_owner_type_slug_index,
             unique: true
           )

    create index(:collections, ["COALESCE(owner_user_id, 0)", :slug],
             name: :collections_owner_slug_index,
             unique: true
           )

    create index(:reports, ["COALESCE(owner_user_id, 0)", :slug],
             name: :reports_owner_slug_index,
             unique: true
           )
  end

  def down do
    drop_if_exists index(:knowledge_pages, ["COALESCE(owner_user_id, 0)", :page_type, :slug],
                     name: :knowledge_pages_owner_type_slug_index
                   )

    drop_if_exists index(:collections, ["COALESCE(owner_user_id, 0)", :slug],
                     name: :collections_owner_slug_index
                   )

    drop_if_exists index(:reports, ["COALESCE(owner_user_id, 0)", :slug],
                     name: :reports_owner_slug_index
                   )

    create index(:knowledge_pages, [:workspace_id, :slug],
             name: :knowledge_pages_workspace_id_slug_index,
             unique: true
           )

    create index(:collections, [:workspace_id, :slug],
             name: :collections_workspace_id_slug_index,
             unique: true
           )

    create index(:reports, [:workspace_id, :slug],
             name: :reports_workspace_id_slug_index,
             unique: true
           )
  end
end
