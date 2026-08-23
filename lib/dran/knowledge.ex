defmodule Dran.Knowledge do
  @moduledoc """
  The Knowledge context — public API for the second brain content.

  Owns workspaces, pages (CRUD, embeds, renames), relations, page
  versions, search (FTS / fuzzy / semantic / hybrid), the audit log,
  lint/health checks and stats/metrics. Goal, collection and report CRUD
  live in their own contexts: `Dran.Goals`, `Dran.Collections`, and
  `Dran.Reports`.

  ## Usage

      # Create a context
      {:ok, ctx} = Dran.Knowledge.create_workspace(%{name: "Personal", slug: "personal"})

      # Create a page
      {:ok, page} = Dran.Knowledge.create_page(%{
        workspace_id: ctx.id,
        title: "Elixir",
        slug: "elixir",
        body: "A functional language...",
        page_type: "entity",
        tags: ["programming", "elixir"]
      })

      # Search
      {:ok, results} = Dran.Knowledge.search("functional language", ctx.id)
  """

  import Ecto.Query, warn: false

  alias Dran.Repo

  alias Dran.{
    Workspace,
    Page,
    Relation,
    PageVersion,
    Log
  }

  # ──────────────────────────────────────────────────────────────────────────
  # Contexts
  # ──────────────────────────────────────────────────────────────────────────

  @doc "List all contexts"
  def list_workspaces do
    Repo.all(from c in Workspace, order_by: [asc: c.name])
  end

  @doc """
  Returns a map of `workspace_id => page_count` for all contexts.

  Lightweight single query (group_by) used by the context selector
  to show page counts next to each context name. Called once per mount,
  never per render.
  """
  def page_counts_by_workspace do
    Repo.all(
      from p in Page,
        where: p.archived == false,
        group_by: p.workspace_id,
        select: {p.workspace_id, count(p.id)}
    )
    |> Map.new()
  end

  @doc "Get a context by slug"
  def get_workspace_by_slug(slug) when is_binary(slug) do
    Repo.one(from c in Workspace, where: c.slug == ^slug)
  end

  @doc """
  List all workspaces, ordered by name.
  """
  def list_home_workspaces do
    list_workspaces()
  end

  @doc """
  List pinned pages for a context.
  """
  def list_pinned_pages(workspace_id) when is_binary(workspace_id) do
    from(p in Page,
      where: p.workspace_id == ^workspace_id and p.pinned == true and p.archived == false,
      order_by: [asc: p.title]
    )
    |> Repo.all()
  end

  @doc "Get a context by id"
  def get_workspace!(id), do: Repo.get!(Workspace, id)

  @doc "Create a new context"
  def create_workspace(attrs) do
    %Workspace{}
    |> Workspace.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update a context"
  def update_workspace(%Workspace{} = context, attrs) do
    context
    |> Workspace.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a context (cascades to pages, relations, etc.).

  API keys whose LAST workspace was this one are revoked automatically —
  the FK cascade removes their `api_key_workspaces` rows, but a key with no
  workspaces left must not keep a working token (SEC: orphan tokens).
  """
  def delete_workspace(%Workspace{} = context) do
    Repo.transaction(fn ->
      # Keys that currently include this workspace AND no other
      orphan_keys =
        from(k in Dran.Accounts.ApiKey,
          join: akw in Dran.Accounts.ApiKeyWorkspace,
          on: akw.api_key_id == k.id,
          where: akw.workspace_id == ^context.id and k.revoked_at |> is_nil(),
          group_by: k.id,
          having: count(akw.workspace_id) == 1
        )
        |> Repo.all()

      result = Repo.delete(context)

      # The cascade has now removed the join rows; revoke the orphans.
      now = DateTime.utc_now(:second)

      Enum.each(orphan_keys, fn key ->
        Repo.update_all(
          from(k in Dran.Accounts.ApiKey, where: k.id == ^key.id),
          set: [revoked_at: now]
        )
      end)

      result
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Pages
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  List pages with optional filters.

  ## Options
  - `:workspace_id` — filter by context (required for multi-context isolation)
  - `:type` — filter by page_type
  - `:tag` — filter by a single tag
  - `:status` — filter by kanban_status (for todos)
  - `:goal_slug` — filter by planning goal. A page matches when its own
    `meta.goal_slug` equals the value OR (for todos) its `meta.plan_slug`
    points to a plan whose `meta.goal_slug` equals the value. The special
    value `"none"` matches pages with no direct goal_slug and no plan
    goal_slug. Mainly meaningful with `type: "plan"` or `type: "todo"`.
  - `:plan_slug` — filter by `meta.plan_slug`. The special value `"none"`
    matches pages with no/empty plan_slug. Mainly meaningful with
    `type: "todo"`.
  - `:project_slug` — filter by `meta.project_slug`. The special value
    `"none"` matches pages with no/empty project_slug (orphans).
  - `:archived` — `true` returns only archived pages, `false` or omitted
    returns only non-archived pages
  - `:limit` — limit results (default 50)
  - `:include_body` — include full body (default false, lightweight listing)

  Returns lightweight metadata by default. Use `include_body: true` for full content.
  """
  def list_pages(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    type = Keyword.get(opts, :type)
    kind = Keyword.get(opts, :kind)
    tag = Keyword.get(opts, :tag)
    status = Keyword.get(opts, :status)
    owner = Keyword.get(opts, :owner)
    created_by = Keyword.get(opts, :created_by)
    assignee = Keyword.get(opts, :assignee)
    props = Keyword.get(opts, :props)
    pinned = Keyword.get(opts, :pinned)
    archived = Keyword.get(opts, :archived, false)
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    include_body = Keyword.get(opts, :include_body, false)

    # P-03: accept an optional pre-loaded %Workspace{} to avoid the extra
    # Repo.get(Workspace, workspace_id) query in maybe_exclude_disabled_types.
    context = Keyword.get(opts, :workspace)

    base =
      if include_body do
        from(p in Page)
      else
        from p in Page,
          select: %Page{
            id: p.id,
            workspace_id: p.workspace_id,
            title: p.title,
            slug: p.slug,
            body: "",
            page_type: p.page_type,
            summary: p.summary,
            tags: p.tags,
            meta: p.meta,
            kb_confidence: p.kb_confidence,
            kb_source_url: p.kb_source_url,
            kb_contested: p.kb_contested,
            body_hash: p.body_hash,
            version: p.version,
            owner: p.owner,
            created_by: p.created_by,
            updated_by: p.updated_by,
            on_behalf_of: p.on_behalf_of,
            archived: p.archived,
            pinned: p.pinned,
            inserted_at: p.inserted_at,
            updated_at: p.updated_at
          }
      end

    query =
      base
      |> maybe_filter_context(workspace_id)
      |> maybe_exclude_disabled_types(context, workspace_id)
      |> maybe_filter_type(type)
      |> maybe_filter_kind(kind)
      |> maybe_filter_tag(tag)
      |> maybe_filter_status(status)
      |> maybe_filter_owner(owner)
      |> maybe_filter_created_by(created_by)
      |> maybe_filter_assignee(assignee)
      |> maybe_filter_props(props)
      |> maybe_filter_pinned(pinned)
      |> where([p], p.archived == ^archived)
      |> order_by([p], desc: p.updated_at)
      |> limit(^limit)
      |> offset(^offset)

    Repo.all(query)
  end

  # P-03: when the caller already loaded the %Workspace{} struct, use it
  # directly instead of re-querying by id.
  defp maybe_exclude_disabled_types(
         query,
         %Workspace{disabled_page_types: disabled},
         _workspace_id
       )
       when is_list(disabled) and disabled != [] do
    where(query, [p], p.page_type not in ^disabled)
  end

  defp maybe_exclude_disabled_types(query, %Workspace{}, _workspace_id), do: query

  defp maybe_exclude_disabled_types(query, nil, nil), do: query

  defp maybe_exclude_disabled_types(query, nil, workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      %Workspace{disabled_page_types: disabled} when is_list(disabled) and disabled != [] ->
        where(query, [p], p.page_type not in ^disabled)

      _ ->
        query
    end
  end

  defp maybe_filter_context(query, nil), do: query

  defp maybe_filter_context(query, workspace_id) do
    where(query, [p], p.workspace_id == ^workspace_id)
  end

  defp maybe_filter_type(query, nil), do: query

  defp maybe_filter_type(query, type) do
    where(query, [p], p.page_type == ^type)
  end

  # kind filters on meta.kind — used for note sub-kinds like "todo"/"plan"
  defp maybe_filter_kind(query, nil), do: query

  defp maybe_filter_kind(query, kind) do
    where(query, [p], fragment("?->>'kind' = ?", p.meta, ^kind))
  end

  defp maybe_filter_tag(query, nil), do: query

  defp maybe_filter_tag(query, tag) do
    where(query, [p], ^tag in p.tags)
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status) do
    where(query, [p], fragment("?->>'kanban_status' = ?", p.meta, ^status))
  end

  defp maybe_filter_owner(query, nil), do: query

  defp maybe_filter_owner(query, owner) do
    where(query, [p], p.owner == ^owner)
  end

  defp maybe_filter_pinned(query, nil), do: query

  defp maybe_filter_pinned(query, pinned) when is_boolean(pinned) do
    where(query, [p], p.pinned == ^pinned)
  end

  defp maybe_filter_created_by(query, nil), do: query

  defp maybe_filter_created_by(query, created_by) do
    where(query, [p], p.created_by == ^created_by)
  end

  # assignee: nil → no filter; "none" → no assignee set; value → exact match.
  defp maybe_filter_assignee(query, nil), do: query

  defp maybe_filter_assignee(query, "none") do
    where(
      query,
      [p],
      is_nil(fragment("?->>'assignee'", p.meta)) or fragment("?->>'assignee'", p.meta) == ""
    )
  end

  defp maybe_filter_assignee(query, assignee) do
    where(query, [p], fragment("?->>'assignee'", p.meta) == ^assignee)
  end

  # props: nil/empty → no filter; map → one `where` per key/value pair, compared
  # as `meta->'props'->>key = value` (AND logic). Filtering in the DB (rather than
  # post-fetch in memory) keeps limit/offset pagination correct. We use `->>`
  # text comparison (the same pattern as kanban_status/assignee above) because a
  # single jsonb `@>` containment fragment sends the value as a text param that
  # Postgrex doesn't cast to jsonb correctly; per-key text comparison is reliable
  # and hits the meta GIN/expression indexes just the same. Values are compared
  # as text — non-binary values are JSON-encoded so numbers/booleans still match.
  defp maybe_filter_props(query, props) when is_map(props) and map_size(props) > 0 do
    Enum.reduce(props, query, fn {key, value}, q ->
      text_value = if is_binary(value), do: value, else: Jason.encode!(value)

      where(
        q,
        [p],
        fragment("?->'props'->>? = ?", p.meta, ^to_string(key), ^text_value)
      )
    end)
  end

  defp maybe_filter_props(query, _props), do: query

  defp apply_rerank(query_string, results, opts) do
    if Keyword.get(opts, :rerank, Dran.Inference.Config.use_rerank?()) do
      Dran.Rerank.rerank(query_string, results)
    else
      {:ok, results}
    end
  end

  @doc "List notes with kind:todo in a context, optionally filtered by kanban_status"
  def list_todos(workspace_id) when is_binary(workspace_id) do
    list_todos(workspace_id: workspace_id)
  end

  def list_todos(opts) when is_list(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, 500)
    archived = Keyword.get(opts, :archived, false)

    query =
      from(p in Page,
        where:
          p.page_type == "note" and
            p.archived == ^archived and
            fragment("?->>'kind' = 'todo'", p.meta),
        order_by: [asc: p.title],
        limit: ^limit
      )

    query =
      if status do
        where(query, [p], p.kanban_status == ^status)
      else
        query
      end

    query =
      if workspace_id do
        where(query, [p], p.workspace_id == ^workspace_id)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  All distinct tags used in a context, sorted alphabetically. Used for
  tag-input autocomplete suggestions.
  """
  def list_tags(workspace_id) when is_binary(workspace_id) do
    from(p in Page,
      where: p.workspace_id == ^workspace_id and p.archived == false,
      select: p.tags
    )
    |> Repo.all()
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Get a page by slug within a context"
  def get_page_by_slug(slug, workspace_id) when is_binary(slug) and is_binary(workspace_id) do
    Repo.one(from p in Page, where: p.slug == ^slug and p.workspace_id == ^workspace_id)
  end

  @doc "Batch-fetch slug → page_type map for many slugs in one query"
  def get_pages_by_slugs(slugs, workspace_id) when is_list(slugs) and is_binary(workspace_id) do
    slugs =
      slugs
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    case slugs do
      [] ->
        %{}

      [_ | _] = slugs ->
        Repo.all(
          from p in Page,
            where: p.workspace_id == ^workspace_id and p.slug in ^slugs,
            select: {p.slug, p.page_type}
        )
        |> Map.new()
    end
  end

  @doc "Get a page by id"
  def get_page!(id), do: Repo.get!(Page, id)

  @doc "Get a page by id, returns nil if not found"
  def get_page(id), do: Repo.get(Page, id)

  @doc """
  Build a changeset for a page without persisting.

  Used by LiveView forms to render form fields and validate input.
  Returns an `Ecto.Changeset` on a new or existing `%Page{}`.
  """
  def change_page(%Page{} = page, attrs \\ %{}) do
    Page.changeset(page, attrs)
  end

  @doc "List of all valid page types"
  def page_types, do: Page.all_types()

  @doc """
  Page types enabled for a context — all types minus the context's
  `disabled_page_types`.
  """
  def enabled_page_types(%Workspace{} = context) do
    Page.all_types() -- (context.disabled_page_types || [])
  end

  @doc "True if the given page type is enabled in the context."
  def page_type_enabled?(nil, _page_type), do: true

  def page_type_enabled?(%Workspace{} = context, page_type) when is_binary(page_type) do
    page_type not in (context.disabled_page_types || [])
  end

  @doc "Update a context's settings (e.g. disabled_page_types)."
  def update_workspace_settings(%Workspace{} = context, attrs) do
    context
    |> Workspace.settings_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Create a new page. Automatically:
  - Computes body_hash (SHA256)
  - Logs the action to brain_log
  - Broadcasts a PubSub change event for live views
  """
  def create_page(attrs) do
    attrs =
      attrs
      |> normalize_attrs()
      |> default_owner_field("owner", "system")
      |> default_owner_field("created_by", "system")
      |> ensure_title_and_slug()

    with :ok <- check_page_type_enabled(attrs) do
      changeset = Page.create_changeset(attrs)

      case Repo.insert(changeset) do
        {:ok, page} ->
          log_action(page.workspace_id, "page.create", page.slug, %{
            page_id: page.id,
            page_type: page.page_type,
            owner: page.owner,
            created_by: page.created_by
          })

          resolve_embeds(page)

          broadcast_page_change(page.workspace_id, :created, page)
          Dran.Embeddings.schedule(page)
          Dran.PageAugmenter.schedule(page)
          {:ok, page}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp check_page_type_enabled(attrs) do
    workspace_id = attrs["workspace_id"]
    page_type = attrs["page_type"]

    with %Workspace{} = context when not is_nil(workspace_id) <-
           workspace_id && Repo.get(Workspace, workspace_id),
         false <- page_type_enabled?(context, page_type || "note") do
      {:error, :page_type_disabled}
    else
      _ -> :ok
    end
  end

  defp ensure_title_and_slug(attrs) do
    body = attrs["body"] || ""
    title = attrs["title"]
    slug = attrs["slug"]

    title =
      if is_binary(title) and String.trim(title) != "" do
        title
      else
        derive_title(body)
      end

    slug =
      if is_binary(slug) and String.trim(slug) != "" do
        slug
      else
        Dran.Slug.generate(title, attrs["workspace_id"], attrs["page_type"])
      end

    attrs
    |> Map.put("title", title)
    |> Map.put("slug", slug)
  end

  defp derive_title(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "![[") or String.starts_with?(&1, "[[")))
    |> List.first()
    |> case do
      nil -> "Untitled"
      line -> String.slice(line, 0, 512)
    end
  end

  defp default_owner_field(attrs, key, value) do
    if Map.has_key?(attrs, key) do
      attrs
    else
      Map.put(attrs, key, value)
    end
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  @doc """
  Update an existing page. Automatically:
  - Increments version
  - Recomputes body_hash
  - Saves previous body to page_versions
  - Logs the action
  - Broadcasts a PubSub change event for live views
  """
  def update_page(%Page{} = page, attrs) do
    # Save current version snapshot before updating
    if Map.has_key?(attrs, :body) || Map.has_key?(attrs, "body") do
      save_page_version(page)
    end

    changeset = Page.update_changeset(page, attrs)

    case Repo.update(changeset) do
      {:ok, updated_page} ->
        log_action(updated_page.workspace_id, "page.update", updated_page.slug, %{
          page_id: updated_page.id,
          version: updated_page.version
        })

        reresolve_embeds(updated_page)

        broadcast_page_change(updated_page.workspace_id, :updated, updated_page)
        Dran.Embeddings.schedule(updated_page)
        Dran.PageAugmenter.schedule(updated_page)
        {:ok, updated_page}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Archive a page. Archived pages are hidden from lists, stats, orphan
  detection and kanban boards, but remain accessible by direct URL.
  Logs the action and broadcasts a PubSub change event.
  """
  def archive_page(%Page{} = page) do
    log_action(page.workspace_id, "page.archive", page.slug, %{page_id: page.id})

    page
    |> Ecto.Changeset.change(archived: true)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        broadcast_page_change(updated.workspace_id, :updated, updated)
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Unarchive a page, restoring it to lists, stats and boards."
  def unarchive_page(%Page{} = page) do
    log_action(page.workspace_id, "page.unarchive", page.slug, %{page_id: page.id})

    page
    |> Ecto.Changeset.change(archived: false)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        broadcast_page_change(updated.workspace_id, :updated, updated)
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Delete a page. Cascades to relations and page_versions.
  Logs the action and broadcasts a PubSub change event for live views.
  """
  def delete_page(%Page{} = page) do
    log_action(page.workspace_id, "page.delete", page.slug, %{page_id: page.id})
    workspace_id = page.workspace_id

    case Repo.delete(page) do
      {:ok, page} ->
        broadcast_page_change(workspace_id, :deleted, page)
        {:ok, page}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Delete ALL content in a context: pages, relations, page_versions, and logs.

  The context itself is preserved (its slug, name, and settings). This is a
  destructive, irreversible operation intended for resetting a brain to a
  clean state. Returns `{:ok, counts}` where counts is a map of table →
  number of deleted rows.

  ## Example

      {:ok, %{pages: 42, relations: 18, versions: 35, logs: 50}} =
        Dran.Knowledge.reset_context(workspace_id)
  """
  def reset_context(workspace_id) do
    import Ecto.Query, warn: false

    page_ids_sub = page_ids(workspace_id)

    Repo.transaction(fn ->
      # Delete in dependency order: versions → relations → logs → pages.
      # Repo.delete_all/1 returns {count, nil} — extract the count.
      {versions_count, _} =
        from(v in PageVersion, where: v.page_id in subquery(page_ids_sub))
        |> Repo.delete_all()

      {relations_count, _} =
        from(r in Relation,
          where: r.source_id in subquery(page_ids_sub) or r.target_id in subquery(page_ids_sub)
        )
        |> Repo.delete_all()

      {logs_count, _} =
        from(l in Log, where: l.workspace_id == ^workspace_id)
        |> Repo.delete_all()

      {pages_count, _} =
        from(p in Page, where: p.workspace_id == ^workspace_id)
        |> Repo.delete_all()

      %{
        pages: pages_count,
        relations: relations_count,
        versions: versions_count,
        logs: logs_count
      }
    end)
  end

  defp page_ids(workspace_id) do
    from(p in Page, where: p.workspace_id == ^workspace_id, select: p.id)
  end

  @doc """
  Broadcast a page change event over Phoenix.PubSub so live views
  (e.g. the graph) can refresh in real time.

  Subscribers on the "brain:<workspace_id>" topic receive
  `{:page_changed, action, page}` where `action` is `:created`,
  `:updated`, or `:deleted`.
  """
  def broadcast_page_change(workspace_id, action, page) do
    Phoenix.PubSub.broadcast(Dran.PubSub, "brain:#{workspace_id}", {:page_changed, action, page})
    # Invalidate granularly: the page cache entry, the page's subgraph, and
    # the global graph (any page change affects the global view).
    Dran.GraphCache.invalidate_page_slug(page.slug, workspace_id)
    if page.id, do: Dran.GraphCache.invalidate_page(page.id, workspace_id)
  rescue
    # PubSub may not be running during release tasks (bin/dran eval, seeds)
    # where only the repo is started — the broadcast is a UI notification,
    # not a data-integrity concern, so it's safe to skip.
    ArgumentError ->
      :ok
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Relations
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Create a relation between two pages.

  Uses `on_conflict: :nothing` so duplicate `(source, target, type)` tuples
  are silently ignored at the SQL level — critical inside transactions,
  where a unique-violation error would poison the whole transaction.
  """
  def create_relation(attrs) do
    %Relation{}
    |> Relation.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc """
  Create auto-relations from a page to its top semantic neighbours.

  Looks at pages in the same context ordered by cosine distance and creates
  `:semantic` relations for the closest `k` neighbours. Skips relations
  that already exist to avoid duplicates on repeated runs.
  """
  def auto_relate(page_or_nil, opts \\ [])

  def auto_relate(%Page{workspace_id: nil}, _opts), do: {:ok, []}

  def auto_relate(%Page{} = page, opts) do
    import Ecto.Query

    k = Keyword.get(opts, :k, 3)
    exclude_ids = [page.id | Keyword.get(opts, :exclude_ids, [])]

    {results, err} =
      if page.embedding do
        vec = Pgvector.new(page.embedding)

        hits =
          Repo.all(
            from p in Page,
              where: p.workspace_id == ^page.workspace_id and not is_nil(p.embedding),
              where: p.id not in ^exclude_ids,
              order_by: fragment("? <=> ?", p.embedding, ^vec),
              limit: ^k,
              select: %{
                id: p.id,
                distance: fragment("? <=> ?", p.embedding, ^vec)
              }
          )

        {hits, nil}
      else
        # Fallback: embed the text if the page has no stored vector yet
        text = Dran.Embeddings.text_for_page(page)

        case semantic_search(text, workspace_id: page.workspace_id, limit: k + 5) do
          {:ok, hits} ->
            targets =
              hits
              |> Enum.reject(&(&1.id in exclude_ids))
              |> Enum.take(k)

            {targets, nil}

          {:error, reason} ->
            {[], reason}
        end
      end

    if err do
      {:error, err}
    else
      threshold = Dran.PageAugmenter.semantic_threshold(page)

      existing_target_ids =
        list_relations_for_page(page.id)
        |> Map.get(:outbound, [])
        |> Enum.filter(&(&1.relation_type == "semantic"))
        |> Enum.map(& &1.target_id)
        |> MapSet.new()

      created =
        results
        |> Enum.reject(&MapSet.member?(existing_target_ids, &1.id))
        |> Enum.filter(fn target ->
          distance = Map.get(target, :distance)
          is_nil(distance) or distance <= threshold
        end)
        |> Enum.reduce([], fn target, acc ->
          distance = Map.get(target, :distance)

          attrs = %{
            source_id: page.id,
            target_id: target.id,
            relation_type: "semantic",
            weight: distance,
            meta: %{"auto" => true, "distance" => distance}
          }

          inverse_attrs = %{
            source_id: target.id,
            target_id: page.id,
            relation_type: "semantic",
            weight: distance,
            meta: %{"auto" => true, "distance" => distance}
          }

          with {:ok, rel} <- create_relation(attrs),
               {:ok, _} <- create_relation(inverse_attrs) do
            [rel | acc]
          else
            _ -> acc
          end
        end)

      {:ok, Enum.reverse(created)}
    end
  end

  @doc "Create a relation by slugs instead of IDs"
  def create_relation_by_slugs(source_slug, target_slug, relation_type \\ "related", workspace_id) do
    source = get_page_by_slug(source_slug, workspace_id)
    target = get_page_by_slug(target_slug, workspace_id)

    cond do
      is_nil(source) ->
        {:error, :source_not_found}

      is_nil(target) ->
        {:error, :target_not_found}

      true ->
        create_relation(%{
          source_id: source.id,
          target_id: target.id,
          relation_type: relation_type
        })
    end
  end

  @doc "List all relations for a page (inbound + outbound)"
  def list_relations_for_page(page_id) do
    # Lightweight select: join pages but only fetch id, title, slug, page_type — no body.
    # This avoids loading large text bodies that are never needed for relation listing.
    outbound =
      from r in Relation,
        where: r.source_id == ^page_id,
        left_join: t in assoc(r, :target),
        select: %Relation{
          id: r.id,
          source_id: r.source_id,
          target_id: r.target_id,
          relation_type: r.relation_type,
          weight: r.weight,
          meta: r.meta,
          inserted_at: r.inserted_at,
          target: %Page{
            id: t.id,
            title: t.title,
            slug: t.slug,
            page_type: t.page_type
          }
        }

    inbound =
      from r in Relation,
        where: r.target_id == ^page_id,
        left_join: s in assoc(r, :source),
        select: %Relation{
          id: r.id,
          source_id: r.source_id,
          target_id: r.target_id,
          relation_type: r.relation_type,
          weight: r.weight,
          meta: r.meta,
          inserted_at: r.inserted_at,
          source: %Page{
            id: s.id,
            title: s.title,
            slug: s.slug,
            page_type: s.page_type
          }
        }

    %{
      outbound: Repo.all(outbound),
      inbound: Repo.all(inbound)
    }
  end

  @doc """
  Batch version of `list_relations_for_page/1` — loads relations for many
  pages in two queries total (one outbound, one inbound) instead of 2×N.

  Returns `%{page_id => %{outbound: [...], inbound: [...]}}`. Pages with no
  relations are omitted from the map (callers use `Map.get(map, id, %{outbound: [], inbound: []})`).

  Used by search graph mode to avoid the N+1 when building subgraphs for
  each result.
  """
  def list_relations_for_pages(page_ids) when is_list(page_ids) do
    # Outbound: relations where source is any of the pages
    outbound =
      from r in Relation,
        where: r.source_id in ^page_ids,
        left_join: t in assoc(r, :target),
        select: %Relation{
          id: r.id,
          source_id: r.source_id,
          target_id: r.target_id,
          relation_type: r.relation_type,
          weight: r.weight,
          meta: r.meta,
          inserted_at: r.inserted_at,
          target: %Page{
            id: t.id,
            title: t.title,
            slug: t.slug,
            page_type: t.page_type
          }
        }

    # Inbound: relations where target is any of the pages
    inbound =
      from r in Relation,
        where: r.target_id in ^page_ids,
        left_join: s in assoc(r, :source),
        select: %Relation{
          id: r.id,
          source_id: r.source_id,
          target_id: r.target_id,
          relation_type: r.relation_type,
          weight: r.weight,
          meta: r.meta,
          inserted_at: r.inserted_at,
          source: %Page{
            id: s.id,
            title: s.title,
            slug: s.slug,
            page_type: s.page_type
          }
        }

    outbound_list = Repo.all(outbound)
    inbound_list = Repo.all(inbound)

    # Group by the page they belong to
    outbound_grouped = Enum.group_by(outbound_list, & &1.source_id)
    inbound_grouped = Enum.group_by(inbound_list, & &1.target_id)

    all_ids = (Map.keys(outbound_grouped) ++ Map.keys(inbound_grouped)) |> Enum.uniq()

    Map.new(all_ids, fn id ->
      {id,
       %{
         outbound: Map.get(outbound_grouped, id, []),
         inbound: Map.get(inbound_grouped, id, [])
       }}
    end)
  end

  @doc "Delete a relation"
  def delete_relation(%Relation{} = relation), do: Repo.delete(relation)

  @doc """
  Delete relations between two pages by slug.

  If `relation_type` is provided, only deletes relations of that type.
  Otherwise, deletes ALL relations between the two pages (both directions).

  Returns `{deleted_count, []}` on success or `{0, errors}` on failure.
  """
  def delete_relation_by_slugs(source_slug, target_slug, relation_type \\ nil, workspace_id) do
    source = get_page_by_slug(source_slug, workspace_id)
    target = get_page_by_slug(target_slug, workspace_id)

    cond do
      is_nil(source) ->
        {:error, :source_not_found}

      is_nil(target) ->
        {:error, :target_not_found}

      true ->
        query =
          from r in Relation,
            where:
              (r.source_id == ^source.id and r.target_id == ^target.id) or
                (r.source_id == ^target.id and r.target_id == ^source.id)

        query =
          if relation_type do
            where(query, [r], r.relation_type == ^relation_type)
          else
            query
          end

        relations = Repo.all(query)

        {count, errors} =
          Enum.reduce(relations, {0, []}, fn rel, {acc_count, acc_errors} ->
            case Repo.delete(rel) do
              {:ok, _} -> {acc_count + 1, acc_errors}
              {:error, _} -> {acc_count, ["failed to delete relation" | acc_errors]}
            end
          end)

        {count, Enum.reverse(errors)}
    end
  end

  @doc """
  Find candidate transitive `part_of` relations via a recursive CTE.

  Given a chain `A part_of B part_of C`, returns the pair `(A, C)` if the
  direct edge `A part_of C` does not already exist. Each result carries
  the intermediate page `B` as evidence:

      %{source_slug, target_slug, via_slug}

  Depth is capped at 2 (A→B→C). Cycles are guarded with a `visited` array
  so a self-referencing chain (e.g. A→B→A) cannot recurse infinitely.
  Limited to 50 candidates per context.

  Implemented as raw SQL via `Ecto.Adapters.SQL.query/3` because the
  recursive CTE with cycle guard (`NOT source_id = ANY(visited)`) and the
  `NOT EXISTS` anti-join are simpler to express in SQL than in Ecto's DSL.
  """
  def transitive_part_of_candidates(workspace_id) do
    sql = """
    WITH RECURSIVE chain AS (
      SELECT r.source_id, r.target_id, r.target_id AS via_id, 1 AS depth,
             ARRAY[r.source_id] AS visited
      FROM relations r
      JOIN pages p ON p.id = r.source_id
      WHERE r.relation_type = 'part_of' AND p.workspace_id = $1::uuid

      UNION

      SELECT c.source_id, r.target_id, c.target_id, c.depth + 1, c.visited || r.source_id
      FROM chain c
      JOIN relations r ON r.source_id = c.target_id AND r.relation_type = 'part_of'
      WHERE c.depth < 2 AND NOT (r.source_id = ANY(c.visited))
    )
    SELECT DISTINCT ps.slug AS source_slug, pt.slug AS target_slug, pv.slug AS via_slug
    FROM chain c
    JOIN pages ps ON ps.id = c.source_id
    JOIN pages pt ON pt.id = c.target_id
    JOIN pages pv ON pv.id = c.via_id
    WHERE c.depth = 2
      AND c.source_id != c.target_id
      AND NOT EXISTS (
        SELECT 1 FROM relations r2
        WHERE r2.source_id = c.source_id AND r2.target_id = c.target_id
          AND r2.relation_type = 'part_of'
      )
    LIMIT 50
    """

    case Ecto.Adapters.SQL.query(Repo, sql, [Ecto.UUID.dump!(workspace_id)]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [s, t, v] ->
          %{source_slug: s, target_slug: t, via_slug: v}
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  List pages belonging to a detected cluster.

  Queries pages by the `cluster_id` value stored in their `meta` JSONB
  (written by `Dran.Graph.refresh_clusters/1`). Returns lightweight
  maps `%{id, slug, title, page_type}` — no body, no embeddings.

  The filter uses `(meta->>'cluster_id')::int = ?` so it works against
  the text representation of the JSONB value cast to an integer, matching
  how `refresh_clusters/1` writes the value.
  """
  @spec cluster_pages(binary(), integer()) :: [map()]
  def cluster_pages(workspace_id, cluster_id) do
    Repo.all(
      from p in Page,
        where: p.workspace_id == ^workspace_id,
        where: fragment("(meta->>'cluster_id')::int = ?", ^cluster_id),
        select: %{id: p.id, slug: p.slug, title: p.title, page_type: p.page_type}
    )
  end

  @doc """
  Build the full graph (nodes + edges) for a context.

  Returns `%{nodes: [...], edges: [...], total_nodes: int, total_edges: int}`
  where each edge is `%{source, target, type, weight}` and each node is
  `%{id, title, slug, type}` plus `summary`/`tags` when not capped. Used by
  the graph LiveView and the `/api/graph` endpoint.

  ## Options

  - `:exclude_types` — page types excluded from the graph entirely. Filtered
    in SQL so the operational layer never leaves the database.
  - `:max_nodes` — hard cap: when the context has more visible pages than
    this, only the N most-connected pages (highest degree, counting inbound
    + outbound relations) are returned, plus the edges between them. The
    `total_nodes` always reports the real count; `total_edges` reports the
    real count when capped (otherwise it reflects the fetched edges, capped
    at 2500). The UI can show "showing X of Y". Keeps the 3D view fluid on
    large brains.
  """
  @max_graph_edges 2500

  def graph_data(workspace_id, opts \\ []) do
    exclude_types = Keyword.get(opts, :exclude_types, [])
    max_nodes = Keyword.get(opts, :max_nodes)

    {page_nodes, total_pages} =
      cond do
        is_nil(max_nodes) ->
          nodes =
            Repo.all(
              from p in graph_base(workspace_id, exclude_types),
                select: %{
                  id: p.id,
                  title: p.title,
                  slug: p.slug,
                  type: p.page_type,
                  summary: p.summary,
                  tags: p.tags
                }
            )

          {nodes, length(nodes)}

        true ->
          total = Repo.aggregate(graph_base(workspace_id, exclude_types), :count)

          nodes =
            if total <= max_nodes do
              Repo.all(
                from p in graph_base(workspace_id, exclude_types),
                  select: %{id: p.id, title: p.title, slug: p.slug, type: p.page_type}
              )
            else
              top_ids = top_connected_ids(workspace_id, exclude_types, max_nodes)

              if top_ids == [] do
                []
              else
                Repo.all(
                  from p in graph_base(workspace_id, exclude_types),
                    where: p.id in ^top_ids,
                    select: %{id: p.id, title: p.title, slug: p.slug, type: p.page_type}
                )
              end
            end

          {nodes, total}
      end

    # Goals are first-class entities (own table, not pages). Load them as
    # graph nodes with type "goal" so they appear alongside pages. Goals
    # don't compete with pages for the max_nodes cap — they're additive.
    goal_nodes =
      Repo.all(
        from g in Dran.Goal,
          where: (g.workspace_id == ^workspace_id and is_nil(g.archived)) or g.archived == false,
          select: %{id: g.id, title: g.title, slug: g.slug, type: fragment("'goal'")}
      )

    nodes = page_nodes ++ goal_nodes
    total_nodes = total_pages + length(goal_nodes)

    node_ids = Enum.map(page_nodes, & &1.id)
    goal_ids = Enum.map(goal_nodes, & &1.id)

    edges =
      if Enum.empty?(node_ids) and Enum.empty?(goal_ids) do
        []
      else
        # Page↔Page edges (both endpoints are pages)
        page_edges =
          if Enum.empty?(node_ids) do
            []
          else
            Repo.all(
              from r in Relation,
                where: r.source_id in ^node_ids and r.target_id in ^node_ids,
                order_by: [desc: r.weight],
                limit: @max_graph_edges,
                select: %{
                  source: r.source_id,
                  target: r.target_id,
                  type: r.relation_type,
                  weight: r.weight
                }
            )
          end

        # Page→Goal edges (source is a page, target is a goal)
        goal_edges =
          if Enum.empty?(node_ids) or Enum.empty?(goal_ids) do
            []
          else
            Repo.all(
              from r in Relation,
                where: r.source_id in ^node_ids and r.target_id in ^goal_ids,
                select: %{
                  source: r.source_id,
                  target: r.target_id,
                  type: r.relation_type,
                  weight: r.weight
                }
            )
          end

        page_edges ++ goal_edges
      end

    total_edges =
      if total_nodes <= length(nodes) do
        length(edges)
      else
        q =
          from r in Relation,
            join: s in assoc(r, :source),
            join: t in assoc(r, :target),
            where: s.workspace_id == ^workspace_id and t.workspace_id == ^workspace_id

        q =
          if exclude_types == [] do
            q
          else
            from [r, s, t] in q,
              where: s.page_type not in ^exclude_types and t.page_type not in ^exclude_types
          end

        Repo.aggregate(q, :count)
      end

    %{nodes: nodes, edges: edges, total_nodes: total_nodes, total_edges: total_edges}
  end

  # Base page query for the graph, scoped to the context and optionally
  # excluding page types (filtered in SQL so hidden types never load).
  defp graph_base(workspace_id, exclude_types) do
    if exclude_types == [] do
      from p in Page, where: p.workspace_id == ^workspace_id
    else
      from p in Page,
        where: p.workspace_id == ^workspace_id and p.page_type not in ^exclude_types
    end
  end

  # The N most-connected page ids in the context, ranked by total degree
  # (inbound + outbound relations), excluding the given types. Uses two
  # SQL GROUP-BY queries instead of loading every (source,target) pair into
  # RAM and counting in Elixir — scales linearly with page count, not edge
  # count. Only relations whose BOTH endpoints are non-excluded count toward
  # the degree, matching what the graph actually renders.
  defp top_connected_ids(workspace_id, exclude_types, limit) do
    out_base =
      from r in Relation,
        join: s in assoc(r, :source),
        join: t in assoc(r, :target),
        where: s.workspace_id == ^workspace_id and t.workspace_id == ^workspace_id

    out_base =
      if exclude_types == [] do
        out_base
      else
        from [r, s, t] in out_base,
          where: s.page_type not in ^exclude_types and t.page_type not in ^exclude_types
      end

    in_base =
      from r in Relation,
        join: s in assoc(r, :source),
        join: t in assoc(r, :target),
        where: s.workspace_id == ^workspace_id and t.workspace_id == ^workspace_id

    in_base =
      if exclude_types == [] do
        in_base
      else
        from [r, s, t] in in_base,
          where: s.page_type not in ^exclude_types and t.page_type not in ^exclude_types
      end

    out_degree =
      from [r, s, t] in out_base,
        group_by: r.source_id,
        select: {r.source_id, count(r.id)}

    in_degree =
      from [r, s, t] in in_base,
        group_by: r.target_id,
        select: {r.target_id, count(r.id)}

    out = Map.new(Repo.all(out_degree))
    in_ = Map.new(Repo.all(in_degree))

    Map.merge(out, in_, fn _k, v1, v2 -> v1 + v2 end)
    |> Enum.sort_by(fn {_id, degree} -> degree end, :desc)
    |> Enum.take(limit)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Real page counts per type for a context (archived included, matching the
  global graph). Used by the graph sidebar so totals stay truthful even when
  the rendered graph is capped.
  """
  def graph_type_counts(workspace_id, exclude_types \\ []) do
    page_counts =
      Repo.all(
        from p in graph_base(workspace_id, exclude_types),
          group_by: p.page_type,
          select: {p.page_type, count(p.id)}
      )
      |> Map.new()

    goal_count =
      Repo.one(
        from g in Dran.Goal,
          where: g.workspace_id == ^workspace_id and (is_nil(g.archived) or g.archived == false),
          select: count(g.id)
      )

    Map.put(page_counts, "goal", goal_count || 0)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Search
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Unified search across pages.

  Automatically picks the best available strategy:

  - `:hybrid` — when inference is configured and the query is "meaningful"
    (more than 2 words or >25 chars). Combines FTS + semantic search + RRF.
  - `:fuzzy_fts` — short queries (≤2 words and ≤25 chars). Tries fuzzy title
    match plus full-text search.
  - `:fts` — fallback full-text search.

  You can force a strategy with `:strategy`:

      Knowledge.search("elixir phoenix", workspace_id: ctx.id, strategy: :fuzzy)
      Knowledge.search("cómo funciona el embedding", workspace_id: ctx.id, strategy: :hybrid)

  ## Options
  - `:workspace_id` — scope to a context (recommended)
  - `:type` — filter by page_type
  - `:limit` — max results (default 20)
  - `:strategy` — `:auto` (default), `:fts`, `:fuzzy`, `:semantic`, `:hybrid`
  - `:k` — RRF constant for hybrid (default 60)
  - `:rerank` — boolean, overrides `DRAN_INFERENCE_USE_RERANK`

  Returns `{:ok, [result]}` where each result is a normalized map:

      %{
        id: ..., title: ..., slug: ..., page_type: ..., tags: [...],
        excerpt: "...", similarity: nil, distance: nil, score: nil,
        source: :fts | :fuzzy | :fuzzy_fts | :semantic | :hybrid
      }
  """
  def search(query_string, opts \\ []) do
    requested_strategy = Keyword.get(opts, :strategy, :auto)
    strategy = resolve_strategy(requested_strategy, query_string)
    props = Keyword.get(opts, :props)

    case do_search(query_string, opts, strategy) do
      {:error, :not_configured} when requested_strategy != :auto ->
        {:error, :not_configured}

      # Auto strategy should never hard-fail — not_configured, host down,
      # timeout, etc. all fall back to fts so search always works.
      {:error, _reason} when requested_strategy == :auto ->
        do_search(query_string, opts, :fts)
        |> normalize_results(:fts)
        |> maybe_filter_results_by_props(props)

      result ->
        normalize_results(result, strategy)
        |> maybe_filter_results_by_props(props)
    end
  end

  # Post-query props filter for search results. Applied after normalize_results
  # so it works uniformly across all strategies (fts/fuzzy/semantic/hybrid).
  # Each result's `props` must contain ALL the given key-value pairs.
  defp maybe_filter_results_by_props({:ok, results}, props)
       when is_map(props) and map_size(props) > 0 do
    filtered =
      Enum.filter(results, fn result ->
        result_props = Map.get(result, :props, %{})
        Enum.all?(props, fn {k, v} -> Map.get(result_props, k) == v end)
      end)

    {:ok, filtered}
  end

  defp maybe_filter_results_by_props(result, _props), do: result

  @doc """
  Full-text search across pages within a context.

  Uses PostgreSQL FTS with Spanish stemming + unaccent. Returns
  excerpts (not full bodies) to save tokens.

  ## Options
  - `:workspace_id` — scope to a context (recommended)
  - `:type` — filter by page_type
  - `:limit` — max results (default 20)
  """
  def fts_search(query_string, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    type = Keyword.get(opts, :type)
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    # Build tsquery with prefix matching
    tsquery = String.replace(query_string, ~r/\s+/, " & ")

    # P-06: compute excerpt in the main query's select instead of one
    # Repo.one(ts_headline...) per result row (was N+1: 21 queries for 20 results)
    base =
      from p in Page,
        where: fragment("search_vector @@ plainto_tsquery('spanish', ?)", ^tsquery),
        where: p.archived == false,
        order_by:
          fragment("ts_rank(search_vector, plainto_tsquery('spanish', ?)) DESC", ^tsquery),
        limit: ^limit,
        offset: ^offset,
        select: %{
          page: p,
          excerpt:
            fragment(
              "ts_headline('spanish', immutable_unaccent(coalesce(body, '')), plainto_tsquery('spanish', ?), 'MaxWords=35, MinWords=15')",
              ^tsquery
            )
        }

    query =
      base
      |> maybe_filter_context(workspace_id)
      |> maybe_filter_type(type)

    results = Repo.all(query)

    excerpts = Enum.map(results, fn %{page: page, excerpt: excerpt} -> {page, excerpt} end)

    apply_rerank(query_string, excerpts, opts)
  end

  @doc """
  Fuzzy search using pg_trgm similarity. Good for catching typos.

  Returns pages sorted by similarity score (desc).
  """
  def fuzzy_search(query_string, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    limit = Keyword.get(opts, :limit, 10)
    offset = Keyword.get(opts, :offset, 0)

    query =
      from p in Page,
        where: fragment("immutable_unaccent(title) % ?", ^query_string),
        where: p.archived == false,
        order_by: fragment("similarity(immutable_unaccent(title), ?) DESC", ^query_string),
        limit: ^limit,
        offset: ^offset,
        select: %{
          id: p.id,
          slug: p.slug,
          title: p.title,
          page_type: p.page_type,
          tags: p.tags,
          similarity: fragment("similarity(immutable_unaccent(title), ?)", ^query_string)
        }

    query =
      if workspace_id do
        where(query, [p], p.workspace_id == ^workspace_id)
      else
        query
      end

    {:ok, Repo.all(query)}
  end

  @doc """
  Semantic search using pgvector + cosine distance.

  Returns pages sorted by cosine distance to the query embedding (ascending).

  ## Options
  - `:workspace_id` — scope to a context
  - `:type` — filter by page_type
  - `:limit` — max results (default 20)
  """
  @spec semantic_search(String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def semantic_search(query_string, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    type = Keyword.get(opts, :type)
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    case Dran.Inference.embed(query_string) do
      {:ok, vector} ->
        vec = Pgvector.new(vector)

        query =
          from p in Page,
            where: not is_nil(p.embedding),
            where: p.archived == false,
            order_by: fragment("? <=> ?", p.embedding, ^vec),
            limit: ^limit,
            offset: ^offset,
            select: %{
              id: p.id,
              title: p.title,
              slug: p.slug,
              page_type: p.page_type,
              tags: p.tags,
              meta: p.meta,
              distance: fragment("? <=> ?", p.embedding, ^vec)
            }

        query =
          query
          |> maybe_filter_context(workspace_id)
          |> maybe_filter_type(type)

        results = Repo.all(query)
        apply_rerank(query_string, results, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Hybrid search combining full-text search and semantic search using
  Reciprocal Rank Fusion (RRF).

  ## Options
  - `:workspace_id` — scope to a context
  - `:type` — filter by page_type
  - `:limit` — max results (default 20)
  - `:k` — RRF constant (default 60)
  """
  @spec hybrid_search(String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def hybrid_search(query_string, opts \\ []) do
    k = Keyword.get(opts, :k, 60)

    with {:ok, fts} <- fts_search(query_string, Keyword.put(opts, :limit, 50)),
         {:ok, semantic} <- semantic_search(query_string, Keyword.put(opts, :limit, 50)) do
      fts =
        Enum.map(fts, fn {page, excerpt} ->
          %{
            id: page.id,
            title: page.title,
            slug: page.slug,
            page_type: page.page_type,
            tags: page.tags,
            meta: page.meta,
            excerpt: excerpt
          }
        end)

      scored =
        %{}
        |> fuse_rank(fts, k, :excerpt)
        |> fuse_rank(semantic, k, :semantic_distance)
        |> apply_pagerank_boost()

      results =
        scored
        |> Enum.sort_by(fn {_id, %{score: s}} -> s end, :desc)
        |> Enum.take(Keyword.get(opts, :limit, 20))
        |> Enum.map(fn {_id, result} -> result end)

      apply_rerank(query_string, results, opts)
    end
  end

  defp fuse_rank(acc, list, k, extra_field) do
    list
    |> Enum.with_index(1)
    |> Enum.reduce(acc, fn {item, rank}, acc ->
      {page, excerpt} = normalize_fuse_item(item)
      score = 1.0 / (k + rank)

      existing =
        Map.get(acc, page.id, %{
          id: page.id,
          title: page.title,
          slug: page.slug,
          page_type: page.page_type,
          tags: page.tags,
          meta: Map.get(page, :meta) || %{},
          excerpt: excerpt,
          score: 0.0
        })

      merged =
        existing
        |> Map.put(:score, existing.score + score)
        |> Map.put_new(extra_field, Map.get(page, extra_field))
        # Ensure meta is carried through once both sources have had a chance.
        |> Map.put_new(:meta, Map.get(page, :meta) || %{})

      Map.put(acc, page.id, merged)
    end)
  end

  defp normalize_fuse_item({%Dran.Page{} = page, excerpt}), do: {page, excerpt}
  defp normalize_fuse_item(%{} = map), do: {map, Map.get(map, :excerpt)}

  # ── PageRank authority boost ──
  #
  # After RRF fusion, multiply each result's score by `(1.0 + boost * pagerank)`.
  # Pages with no `pagerank` in meta get exactly 1.0 (boost * 0.0 = 0), so they
  # behave identically to before this feature was introduced.
  defp apply_pagerank_boost(scored) do
    boost = Dran.Settings.get("pagerank_boost")

    if boost > 0.0 do
      Enum.map(scored, fn {id, result} ->
        pagerank =
          result
          |> Map.get(:meta, %{})
          |> get_in(["pagerank"])
          |> case do
            n when is_number(n) -> n * 1.0
            _ -> 0.0
          end

        boosted = result.score * (1.0 + boost * pagerank)
        {id, Map.put(result, :score, boosted)}
      end)
    else
      scored
    end
  end

  # ── Unified search internals ──

  defp resolve_strategy(:auto, query_string) do
    inference? = Dran.Inference.enabled?()
    meaningful? = meaningful_query?(query_string)

    cond do
      meaningful? and inference? -> :hybrid
      meaningful? -> :fts
      inference? -> :fuzzy_fts
      true -> :fuzzy_fts
    end
  end

  defp resolve_strategy(strategy, _query)
       when strategy in [:fts, :fuzzy, :fuzzy_fts, :semantic, :hybrid] do
    strategy
  end

  defp resolve_strategy(_strategy, _query), do: :fts

  defp meaningful_query?(query_string) do
    words = query_string |> String.split(~r/\s+/, trim: true) |> length()
    chars = String.length(query_string)
    words > 2 or chars > 25
  end

  defp do_search(query_string, opts, :fts) do
    fts_search(query_string, opts)
  end

  defp do_search(query_string, opts, :fuzzy) do
    fuzzy_search(query_string, opts)
  end

  defp do_search(query_string, opts, :fuzzy_fts) do
    limit = Keyword.get(opts, :limit, 20)

    with {:ok, fuzzy} <- fuzzy_search(query_string, Keyword.put(opts, :limit, limit)),
         {:ok, fts} <- fts_search(query_string, Keyword.put(opts, :limit, limit)) do
      scored =
        %{}
        |> fuse_rank(fuzzy, 60, :similarity)
        |> fuse_rank(fts, 60, :excerpt)
        |> Enum.sort_by(fn {_id, %{score: s}} -> s end, :desc)
        |> Enum.take(limit)
        |> Enum.map(fn {_id, result} -> result end)

      apply_rerank(query_string, scored, opts)
    end
  end

  defp do_search(query_string, opts, :semantic) do
    semantic_search(query_string, opts)
  end

  defp do_search(query_string, opts, :hybrid) do
    hybrid_search(query_string, opts)
  end

  defp normalize_results({:error, _} = error, _strategy), do: error

  defp normalize_results({:ok, results}, strategy) when is_list(results) do
    {:ok, Enum.map(results, &normalize_item(&1, strategy))}
  end

  defp normalize_item({%Dran.Page{} = page, excerpt}, strategy) do
    %{
      id: page.id,
      title: page.title,
      slug: page.slug,
      page_type: page.page_type,
      tags: page.tags || [],
      props: get_in(page.meta || %{}, ["props"]) || %{},
      excerpt: excerpt || "",
      similarity: nil,
      distance: nil,
      score: nil,
      source: strategy
    }
  end

  defp normalize_item(%{} = item, strategy) do
    %{
      id: Map.get(item, :id) || Map.get(item, "id"),
      title: Map.get(item, :title) || Map.get(item, "title"),
      slug: Map.get(item, :slug) || Map.get(item, "slug"),
      page_type: Map.get(item, :page_type) || Map.get(item, "page_type"),
      tags: List.wrap(Map.get(item, :tags) || Map.get(item, "tags")),
      props: Map.get(item, :props) || Map.get(item, "props") || %{},
      excerpt: Map.get(item, :excerpt) || Map.get(item, "excerpt") || "",
      similarity: Map.get(item, :similarity) || Map.get(item, "similarity"),
      distance: Map.get(item, :distance) || Map.get(item, "distance"),
      score: Map.get(item, :score) || Map.get(item, "score"),
      source: strategy
    }
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Page Versions
  # ──────────────────────────────────────────────────────────────────────────

  @doc "List all versions of a page (history)"
  def list_page_versions(page_id) do
    Repo.all(
      from pv in PageVersion,
        where: pv.page_id == ^page_id,
        order_by: [desc: pv.version]
    )
  end

  @doc "Get a specific version of a page"
  def get_page_version(page_id, version) do
    Repo.one(
      from pv in PageVersion,
        where: pv.page_id == ^page_id and pv.version == ^version
    )
  end

  defp save_page_version(%Page{} = page) do
    %PageVersion{}
    |> PageVersion.changeset(%{
      page_id: page.id,
      body: page.body,
      body_hash: page.body_hash,
      version: page.version,
      changed_by: page.updated_by || "system"
    })
    |> Repo.insert()
  end

  @doc """
  Compute a line-level diff between a page's current body and a
  historical version.

  Returns `{:ok, %{from:, to:, changes: %{added:, removed:, unchanged:}}}`
  on success, or `{:error, :version_not_found}` when the requested
  version doesn't exist.

  The diff is multiset-based: each line is counted by frequency, so
  `added` = lines present in the new body but not in the old (by count),
  `removed` = lines present in the old body but not in the new (by count),
  and `unchanged` = lines common to both (by count).
  """
  def version_diff(%Page{} = page, version) when is_integer(version) do
    case get_page_version(page.id, version) do
      nil ->
        {:error, :version_not_found}

      %PageVersion{} = old ->
        new_lines = String.split(page.body || "", "\n")
        old_lines = String.split(old.body || "", "\n")

        new_freq = Enum.frequencies(new_lines)
        old_freq = Enum.frequencies(old_lines)

        all_lines = MapSet.new(Map.keys(new_freq) ++ Map.keys(old_freq))

        {added, removed, unchanged} =
          Enum.reduce(all_lines, {0, 0, 0}, fn line, {a, r, u} ->
            n = Map.get(new_freq, line, 0)
            o = Map.get(old_freq, line, 0)
            {a + max(0, n - o), r + max(0, o - n), u + min(n, o)}
          end)

        {:ok,
         %{
           from: old.version,
           to: page.version,
           changes: %{added: added, removed: removed, unchanged: unchanged}
         }}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Log
  # ──────────────────────────────────────────────────────────────────────────

  @doc "List recent log entries"
  def list_log(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    action = Keyword.get(opts, :action)
    limit = Keyword.get(opts, :limit, 50)

    query =
      from l in Log,
        order_by: [desc: l.inserted_at],
        limit: ^limit

    query =
      if workspace_id do
        where(query, [l], l.workspace_id == ^workspace_id)
      else
        query
      end

    query =
      if action do
        where(query, [l], l.action == ^action)
      else
        query
      end

    Repo.all(query)
  end

  def count_log(workspace_id) when is_binary(workspace_id) do
    Repo.aggregate(from(l in Log, where: l.workspace_id == ^workspace_id), :count)
  end

  defp log_action(workspace_id, action, subject, details) do
    %Log{}
    |> Log.changeset(%{
      workspace_id: workspace_id,
      action: action,
      subject: subject,
      details: details
    })
    |> Repo.insert()
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Embeds
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Extract ![[embeds]] from a markdown body.

  Returns a list of `%{slug: "page-slug", display: "alt text"}` maps.
  Display text defaults to the slug if not specified.

  ## Formats
  - `![[slug]]` → `%{slug: "slug", display: "slug"}`
  - `![[slug|Alt Text]]` → `%{slug: "slug", display: "Alt Text"}`
  """
  def extract_embeds(body) when is_binary(body) do
    regex = ~r/!\[\[([^|\]]+)(?:\|([^\]]+))?\]\]/

    Regex.scan(regex, body)
    |> Enum.map(fn
      [_, slug, display] -> %{slug: String.trim(slug), display: String.trim(display)}
      [_, slug] -> %{slug: String.trim(slug), display: String.trim(slug)}
    end)
    |> Enum.uniq_by(& &1.slug)
  end

  def extract_embeds(_), do: []

  @doc """
  Resolve ![[embeds]] in a page's body and create `embeds` relations.

  Returns `{created_count, not_found_slugs}`.
  """
  def resolve_embeds(%Page{} = page) do
    embeds = extract_embeds(page.body)

    {created, not_found} =
      Enum.reduce(embeds, {0, []}, fn %{slug: slug}, {acc_created, acc_missing} ->
        target = get_page_by_slug(slug, page.workspace_id)

        if target && target.id != page.id do
          case create_relation(%{
                 source_id: page.id,
                 target_id: target.id,
                 relation_type: "embeds"
               }) do
            {:ok, _} -> {acc_created + 1, acc_missing}
            {:error, _} -> {acc_created, [slug | acc_missing]}
          end
        else
          {acc_created, [slug | acc_missing]}
        end
      end)

    {created, Enum.reverse(not_found)}
  end

  @doc """
  Re-resolve a page's embeds after a body update.

  Removes any `embeds` relations whose target slug is no longer referenced
  in the body, then calls `resolve_embeds/1` to create relations for any
  newly-referenced slugs. Idempotent: running it on an unchanged body is
  a no-op (existing relations are kept, and `resolve_embeds/1` is itself
  protected by a unique constraint on `[:source_id, :target_id, :relation_type]`).
  """
  def reresolve_embeds(%Page{} = page) do
    current_slugs =
      page.body
      |> extract_embeds()
      |> Enum.map(& &1.slug)
      |> MapSet.new()

    page.id
    |> list_relations_for_page()
    |> Map.get(:outbound, [])
    |> Enum.filter(&(&1.relation_type == "embeds"))
    |> Enum.each(fn rel ->
      target_slug = rel.target && rel.target.slug

      unless target_slug && MapSet.member?(current_slugs, target_slug) do
        Repo.delete(rel)
      end
    end)

    resolve_embeds(page)
  end

  @doc """
  Rename a page's slug, propagating the change to every page in the same
  context that embeds it via `![[old-slug]]`.

  The rename and all body rewrites run inside a single transaction. Embeds
  relations are kept consistent because `update_page/2` re-resolves them on
  every body change.
  """
  def rename_slug(%Page{} = page, new_slug) do
    workspace_id = page.workspace_id
    old_slug = page.slug

    Repo.transaction(fn ->
      {:ok, updated} = update_page(page, %{"slug" => new_slug})

      pages_with_embed =
        Repo.all(
          from p in Page,
            where: p.workspace_id == ^workspace_id and p.id != ^page.id,
            where: like(p.body, ^"%![[#{old_slug}%")
        )

      Enum.each(pages_with_embed, fn p ->
        new_body = replace_slug_in_body(p.body, old_slug, new_slug)
        {:ok, _} = update_page(p, %{"body" => new_body})
      end)

      updated
    end)
  end

  @doc """
  Fetch embedded pages referenced by `![[slug]]` in a body.

  Returns a map of `slug => %Page{}` for all embeds that resolve to a page
  in the given context. Useful for rendering embedded media in markdown.
  """
  def fetch_embeds(body, workspace_id) when is_binary(body) and is_binary(workspace_id) do
    body
    |> extract_embeds()
    |> Enum.map(& &1.slug)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn slug, acc ->
      case get_page_by_slug(slug, workspace_id) do
        nil -> acc
        page -> Map.put(acc, slug, page)
      end
    end)
  end

  defp replace_slug_in_body(body, old_slug, new_slug)
       when is_binary(body) and is_binary(old_slug) and is_binary(new_slug) do
    # Embeds: ![[old-slug]] and ![[old-slug|display]]
    embed_pattern = ~r/!\[\[(#{Regex.escape(old_slug)})(\|([^\]]+))?\]\]/

    Regex.replace(embed_pattern, body, fn _full, _slug, _pipe_display, display ->
      if display != "" and display != nil do
        "![[#{new_slug}|#{display}]]"
      else
        "![[#{new_slug}]]"
      end
    end)
  end

  defp replace_slug_in_body(body, _old_slug, _new_slug), do: body

  @doc "Find pages with no inbound relations (orphans)"
  def orphan_pages(workspace_id) do
    # left_join + is_nil is more efficient than NOT IN subquery,
    # especially as the relations table grows.
    Repo.all(
      from p in Page,
        left_join: r in Relation,
        on: r.target_id == p.id,
        where: p.workspace_id == ^workspace_id and is_nil(r.id) and p.archived == false,
        order_by: [asc: p.title],
        select: %{slug: p.slug, title: p.title, page_type: p.page_type, updated_at: p.updated_at}
    )
  end

  defp stale_pages(workspace_id, days \\ 90) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    Repo.all(
      from p in Page,
        where: p.workspace_id == ^workspace_id and p.updated_at < ^cutoff and p.archived == false,
        order_by: [asc: p.updated_at],
        select: %{slug: p.slug, title: p.title, page_type: p.page_type, updated_at: p.updated_at}
    )
  end

  defp contested_pages(workspace_id) do
    Repo.all(
      from p in Page,
        where: p.workspace_id == ^workspace_id and p.kb_contested == true and p.archived == false,
        order_by: [asc: p.title],
        select: %{slug: p.slug, title: p.title, page_type: p.page_type}
    )
  end

  @doc """
  Run a full lint report for a context.

  Returns a map with:
  - `:orphans` — pages with no inbound links
  - `:stale` — pages not updated in 90 days
  - `:contested` — pages flagged as contested
  """
  def lint(workspace_id) do
    %{
      orphans: orphan_pages(workspace_id),
      stale: stale_pages(workspace_id),
      contested: contested_pages(workspace_id)
    }
  end

  @doc """
  Compute aggregate statistics for a context.

  Returns a map with:
  - `:total_pages` — total page count
  - `:by_type` — map of page_type => count
  - `:recent` — 5 most recently updated pages
  - `:todos_by_status` — map of kanban_status => count (for todos)
  - `:orphan_count` — number of orphan pages
  - `:total_relations` — number of relations in the context
  """
  def stats(workspace_id) when is_binary(workspace_id) do
    # by_type: single group_by query instead of loading all pages into memory
    by_type =
      Repo.all(
        from p in Page,
          where: p.workspace_id == ^workspace_id and p.archived == false,
          group_by: p.page_type,
          select: {p.page_type, count(p.id)}
      )
      |> Map.new()

    # todos_by_status: group_by on the kanban_status column for notes kind:"todo"
    todos_by_status =
      Repo.all(
        from p in Page,
          where:
            p.workspace_id == ^workspace_id and p.page_type == "note" and p.archived == false and
              fragment("?->>'kind' = 'todo'", p.meta),
          group_by: fragment("coalesce(kanban_status, 'backlog')"),
          select: {fragment("coalesce(kanban_status, 'backlog')"), count(p.id)}
      )
      |> Map.new()

    # recent: lightweight query — only 5 rows, no body needed
    recent =
      Repo.all(
        from p in Page,
          where: p.workspace_id == ^workspace_id and p.archived == false,
          order_by: [desc: p.updated_at],
          limit: 5,
          select: %Page{
            id: p.id,
            workspace_id: p.workspace_id,
            title: p.title,
            slug: p.slug,
            body: "",
            page_type: p.page_type,
            summary: p.summary,
            tags: p.tags,
            meta: p.meta,
            kb_confidence: p.kb_confidence,
            kb_source_url: p.kb_source_url,
            kb_contested: p.kb_contested,
            body_hash: p.body_hash,
            version: p.version,
            owner: p.owner,
            created_by: p.created_by,
            updated_by: p.updated_by,
            on_behalf_of: p.on_behalf_of,
            inserted_at: p.inserted_at,
            updated_at: p.updated_at
          }
      )

    total_pages =
      Repo.aggregate(
        from(p in Page, where: p.workspace_id == ^workspace_id and p.archived == false),
        :count
      )

    total_relations =
      Repo.aggregate(
        from(r in Relation,
          join: p in assoc(r, :source),
          where: p.workspace_id == ^workspace_id
        ),
        :count
      )

    %{
      total_pages: total_pages,
      by_type: by_type,
      recent: recent,
      todos_by_status: todos_by_status,
      orphan_count: length(orphan_pages(workspace_id)),
      total_relations: total_relations
    }
  end

  def stats(_), do: %{}

  # ──────────────────────────────────────────────────────────────────────────
  # Extended metrics (brain health)
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Compute extended brain-health metrics for a context.

  All queries use SQL aggregates (count / sum / group_by) or lightweight
  selects — no full pages are loaded into memory. Returns a map with:

  - `:pages_this_week` — pages created in the last 7 days
  - `:pages_last_week` — pages created in the 7 days before that
  - `:embedding_coverage` — fraction of pages with an embedding (0.0–1.0)
  - `:relations_by_type` — map of relation_type => count
  - `:contested_count` — number of contested pages
  - `:agents` — `%{sessions_this_week, tokens_this_week, total_sessions}`
  """
  def metrics(workspace_id) when is_binary(workspace_id) do
    now = DateTime.utc_now()
    week_ago = DateTime.add(now, -7 * 86400, :second)
    two_weeks_ago = DateTime.add(now, -14 * 86400, :second)

    %{
      pages_this_week: count_pages_since(workspace_id, week_ago),
      pages_last_week:
        count_pages_since(workspace_id, two_weeks_ago) - count_pages_since(workspace_id, week_ago),
      embedding_coverage: embedding_coverage(workspace_id),
      relations_by_type: relations_by_type(workspace_id),
      contested_count: length(contested_pages(workspace_id)),
      agents: agent_metrics(workspace_id)
    }
  end

  def metrics(_), do: %{}

  defp count_pages_since(workspace_id, since) do
    Repo.aggregate(
      from(p in Page,
        where: p.workspace_id == ^workspace_id and p.inserted_at >= ^since
      ),
      :count
    )
  end

  defp embedding_coverage(workspace_id) do
    total = Repo.aggregate(from(p in Page, where: p.workspace_id == ^workspace_id), :count)

    if total == 0 do
      0.0
    else
      embedded =
        Repo.aggregate(
          from(p in Page, where: p.workspace_id == ^workspace_id and not is_nil(p.embedding)),
          :count
        )

      embedded / total
    end
  end

  defp relations_by_type(workspace_id) do
    Repo.all(
      from r in Relation,
        join: p in assoc(r, :source),
        where: p.workspace_id == ^workspace_id,
        group_by: r.relation_type,
        select: {r.relation_type, count(r.id)}
    )
    |> Map.new()
  end

  defp agent_metrics(workspace_id) do
    week_ago = DateTime.add(DateTime.utc_now(), -7 * 86400, :second)

    sessions_this_week =
      Repo.aggregate(
        from(s in Dran.Agent.Session,
          where: s.workspace_id == ^workspace_id and s.inserted_at >= ^week_ago
        ),
        :count
      )

    tokens_this_week =
      Repo.one(
        from s in Dran.Agent.Session,
          where: s.workspace_id == ^workspace_id and s.inserted_at >= ^week_ago,
          select: coalesce(sum(fragment("(meta->>'tokens_used')::bigint")), 0)
      )

    tokens_this_week = Decimal.to_integer(tokens_this_week)

    total_sessions =
      Repo.aggregate(
        from(s in Dran.Agent.Session, where: s.workspace_id == ^workspace_id),
        :count
      )

    %{
      sessions_this_week: sessions_this_week,
      tokens_this_week: tokens_this_week,
      total_sessions: total_sessions
    }
  end
end
