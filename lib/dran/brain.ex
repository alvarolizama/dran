defmodule Dran.Brain do
  @moduledoc """
  The Brain context — public API for managing the second brain.

  This module orchestrates Contexts, Pages, Relations, PageVersions,
  and the audit Log. All operations go through here.

  ## Usage

      # Create a context
      {:ok, ctx} = Dran.Brain.create_context(%{name: "Personal", slug: "personal"})

      # Create a page
      {:ok, page} = Dran.Brain.create_page(%{
        context_id: ctx.id,
        title: "Elixir",
        slug: "elixir",
        body: "A functional language...",
        page_type: "entity",
        tags: ["programming", "elixir"]
      })

      # Search
      {:ok, results} = Dran.Brain.search("functional language", ctx.id)
  """

  import Ecto.Query, warn: false

  alias Dran.Repo
  alias Dran.Brain.{Context, Page, Relation, PageVersion, Log}

  # ──────────────────────────────────────────────────────────────────────────
  # Contexts
  # ──────────────────────────────────────────────────────────────────────────

  @doc "List all contexts"
  def list_contexts do
    Repo.all(from c in Context, order_by: [asc: c.name])
  end

  @doc "Get a context by slug"
  def get_context_by_slug(slug) when is_binary(slug) do
    Repo.one(from c in Context, where: c.slug == ^slug)
  end

  @doc "Get a context by id"
  def get_context!(id), do: Repo.get!(Context, id)

  @doc "Create a new context"
  def create_context(attrs) do
    %Context{}
    |> Context.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update a context"
  def update_context(%Context{} = context, attrs) do
    context
    |> Context.changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete a context (cascades to pages, relations, etc.)"
  def delete_context(%Context{} = context) do
    Repo.delete(context)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Pages
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  List pages with optional filters.

  ## Options
  - `:context_id` — filter by context (required for multi-context isolation)
  - `:type` — filter by page_type
  - `:tag` — filter by a single tag
  - `:status` — filter by kanban_status (for todos)
  - `:limit` — limit results (default 50)
  - `:include_body` — include full body (default false, lightweight listing)

  Returns lightweight metadata by default. Use `include_body: true` for full content.
  """
  def list_pages(opts \\ []) do
    context_id = Keyword.get(opts, :context_id)
    type = Keyword.get(opts, :type)
    tag = Keyword.get(opts, :tag)
    status = Keyword.get(opts, :status)
    owner = Keyword.get(opts, :owner)
    created_by = Keyword.get(opts, :created_by)
    limit = Keyword.get(opts, :limit, 50)
    include_body = Keyword.get(opts, :include_body, false)

    base =
      if include_body do
        from(p in Page)
      else
        from p in Page,
          select: %Page{
            id: p.id,
            context_id: p.context_id,
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
      end

    query =
      base
      |> maybe_filter_context(context_id)
      |> maybe_filter_type(type)
      |> maybe_filter_tag(tag)
      |> maybe_filter_status(status)
      |> maybe_filter_owner(owner)
      |> maybe_filter_created_by(created_by)
      |> order_by([p], desc: p.updated_at)
      |> limit(^limit)

    Repo.all(query)
  end

  defp maybe_filter_context(query, nil), do: query

  defp maybe_filter_context(query, context_id) do
    where(query, [p], p.context_id == ^context_id)
  end

  defp maybe_filter_type(query, nil), do: query

  defp maybe_filter_type(query, type) do
    where(query, [p], p.page_type == ^type)
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

  defp maybe_filter_created_by(query, nil), do: query

  defp maybe_filter_created_by(query, created_by) do
    where(query, [p], p.created_by == ^created_by)
  end

  defp apply_rerank(query_string, results, opts) do
    if Keyword.get(opts, :rerank, Dran.Inference.Config.use_rerank?()) do
      Dran.Rerank.rerank(query_string, results)
    else
      {:ok, results}
    end
  end

  @doc "List todos in a context, optionally filtered by kanban_status"
  def list_todos(context_id) when is_binary(context_id) do
    list_todos(context_id: context_id)
  end

  def list_todos(opts) when is_list(opts) do
    context_id = Keyword.get(opts, :context_id)
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, 200)

    opts =
      [type: "todo", include_body: false, limit: limit]
      |> maybe_put_opt(:context_id, context_id)
      |> maybe_put_opt(:status, status)

    list_pages(opts)
  end

  @doc "List goals in a context"
  def list_goals(context_id) when is_binary(context_id) do
    list_goals(context_id: context_id)
  end

  def list_goals(opts) when is_list(opts) do
    context_id = Keyword.get(opts, :context_id)
    limit = Keyword.get(opts, :limit, 100)

    opts =
      [type: "goal", include_body: false, limit: limit]
      |> maybe_put_opt(:context_id, context_id)

    list_pages(opts)
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @doc "Get a page by slug within a context"
  def get_page_by_slug(slug, context_id) when is_binary(slug) and is_binary(context_id) do
    Repo.one(from p in Page, where: p.slug == ^slug and p.context_id == ^context_id)
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

    changeset = Page.create_changeset(attrs)

    case Repo.insert(changeset) do
      {:ok, page} ->
        log_action(page.context_id, "page.create", page.slug, %{
          page_id: page.id,
          page_type: page.page_type,
          owner: page.owner,
          created_by: page.created_by
        })

        broadcast_page_change(page.context_id, :created, page)
        Dran.Embeddings.schedule(page)
        {:ok, page}

      {:error, changeset} ->
        {:error, changeset}
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
        log_action(updated_page.context_id, "page.update", updated_page.slug, %{
          page_id: updated_page.id,
          version: updated_page.version
        })

        broadcast_page_change(updated_page.context_id, :updated, updated_page)
        Dran.Embeddings.schedule(updated_page)
        {:ok, updated_page}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Delete a page. Cascades to relations and page_versions.
  Logs the action and broadcasts a PubSub change event for live views.
  """
  def delete_page(%Page{} = page) do
    log_action(page.context_id, "page.delete", page.slug, %{page_id: page.id})
    context_id = page.context_id

    case Repo.delete(page) do
      {:ok, page} ->
        broadcast_page_change(context_id, :deleted, page)
        {:ok, page}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Broadcast a page change event over Phoenix.PubSub so live views
  (e.g. the graph) can refresh in real time.

  Subscribers on the "brain:<context_id>" topic receive
  `{:page_changed, action, page}` where `action` is `:created`,
  `:updated`, or `:deleted`.
  """
  def broadcast_page_change(context_id, action, page) do
    Phoenix.PubSub.broadcast(Dran.PubSub, "brain:#{context_id}", {:page_changed, action, page})
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Relations
  # ──────────────────────────────────────────────────────────────────────────

  @doc "Create a relation between two pages"
  def create_relation(attrs) do
    %Relation{}
    |> Relation.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Create a relation by slugs instead of IDs"
  def create_relation_by_slugs(source_slug, target_slug, relation_type \\ "related", context_id) do
    source = get_page_by_slug(source_slug, context_id)
    target = get_page_by_slug(target_slug, context_id)

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
    outbound =
      from r in Relation,
        where: r.source_id == ^page_id,
        preload: [:target]

    inbound =
      from r in Relation,
        where: r.target_id == ^page_id,
        preload: [:source]

    %{
      outbound: trim_preloaded_pages(Repo.all(outbound), :target),
      inbound: trim_preloaded_pages(Repo.all(inbound), :source)
    }
  end

  defp trim_preloaded_pages(relations, assoc_key) do
    Enum.map(relations, fn rel ->
      case Map.get(rel, assoc_key) do
        %Page{} = page -> Map.put(rel, assoc_key, %{page | body: ""})
        _ -> rel
      end
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
  def delete_relation_by_slugs(source_slug, target_slug, relation_type \\ nil, context_id) do
    source = get_page_by_slug(source_slug, context_id)
    target = get_page_by_slug(target_slug, context_id)

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
  Build the full graph (nodes + edges) for a context.

  Returns `%{nodes: [...], edges: [...]}` where each node is
  `%{id, title, slug, type}` and each edge is
  `%{source, target, type}`. Used by the graph LiveView and the
  `/api/graph` endpoint.
  """
  def graph_data(context_id) do
    nodes =
      Repo.all(
        from p in Page,
          where: p.context_id == ^context_id,
          select: %{id: p.id, title: p.title, slug: p.slug, type: p.page_type}
      )

    node_ids = Enum.map(nodes, & &1.id)

    edges =
      if Enum.empty?(node_ids) do
        []
      else
        Repo.all(
          from r in Relation,
            where: r.source_id in ^node_ids and r.target_id in ^node_ids,
            select: %{source: r.source_id, target: r.target_id, type: r.relation_type}
        )
      end

    %{nodes: nodes, edges: edges}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Search
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Full-text search across pages within a context.

  Uses PostgreSQL FTS with Spanish stemming + unaccent. Returns
  excerpts (not full bodies) to save tokens.

  ## Options
  - `:context_id` — scope to a context (recommended)
  - `:type` — filter by page_type
  - `:limit` — max results (default 20)
  """
  def search(query_string, opts \\ []) do
    context_id = Keyword.get(opts, :context_id)
    type = Keyword.get(opts, :type)
    limit = Keyword.get(opts, :limit, 20)

    # Build tsquery with prefix matching
    tsquery = String.replace(query_string, ~r/\s+/, " & ")

    base =
      from p in Page,
        where: fragment("search_vector @@ plainto_tsquery('spanish', ?)", ^tsquery),
        order_by:
          fragment("ts_rank(search_vector, plainto_tsquery('spanish', ?)) DESC", ^tsquery),
        limit: ^limit

    query =
      base
      |> maybe_filter_context(context_id)
      |> maybe_filter_type(type)

    results =
      Repo.all(query)

    # Build excerpts using ts_headline
    excerpts =
      Enum.map(results, fn page ->
        excerpt =
          Repo.one(
            from p in Page,
              where: p.id == ^page.id,
              select:
                fragment(
                  "ts_headline('spanish', immutable_unaccent(coalesce(body, '')), plainto_tsquery('spanish', ?), 'MaxWords=35, MinWords=15')",
                  ^tsquery
                )
          )

        {page, excerpt}
      end)

    apply_rerank(query_string, excerpts, opts)
  end

  @doc """
  Fuzzy search using pg_trgm similarity. Good for catching typos.

  Returns pages sorted by similarity score (desc).
  """
  def fuzzy_search(query_string, opts \\ []) do
    context_id = Keyword.get(opts, :context_id)
    limit = Keyword.get(opts, :limit, 10)

    query =
      from p in Page,
        where: fragment("immutable_unaccent(title) % ?", ^query_string),
        order_by: fragment("similarity(immutable_unaccent(title), ?) DESC", ^query_string),
        limit: ^limit,
        select: %{
          id: p.id,
          slug: p.slug,
          title: p.title,
          page_type: p.page_type,
          similarity: fragment("similarity(immutable_unaccent(title), ?)", ^query_string)
        }

    query =
      if context_id do
        where(query, [p], p.context_id == ^context_id)
      else
        query
      end

    {:ok, Repo.all(query)}
  end

  @doc """
  Semantic search using pgvector + cosine distance.

  Returns pages sorted by cosine distance to the query embedding (ascending).

  ## Options
  - `:context_id` — scope to a context
  - `:type` — filter by page_type
  - `:limit` — max results (default 20)
  """
  @spec semantic_search(String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def semantic_search(query_string, opts \\ []) do
    context_id = Keyword.get(opts, :context_id)
    type = Keyword.get(opts, :type)
    limit = Keyword.get(opts, :limit, 20)

    case Dran.Inference.embed(query_string) do
      {:ok, vector} ->
        vec = Pgvector.new(vector)

        query =
          from p in Page,
            where: not is_nil(p.embedding),
            order_by: fragment("? <=> ?", p.embedding, ^vec),
            limit: ^limit,
            select: %{
              id: p.id,
              title: p.title,
              slug: p.slug,
              page_type: p.page_type,
              tags: p.tags,
              distance: fragment("? <=> ?", p.embedding, ^vec)
            }

        query =
          query
          |> maybe_filter_context(context_id)
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
  - `:context_id` — scope to a context
  - `:type` — filter by page_type
  - `:limit` — max results (default 20)
  - `:k` — RRF constant (default 60)
  """
  @spec hybrid_search(String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def hybrid_search(query_string, opts \\ []) do
    k = Keyword.get(opts, :k, 60)

    with {:ok, fts} <- search(query_string, Keyword.put(opts, :limit, 50)),
         {:ok, semantic} <- semantic_search(query_string, Keyword.put(opts, :limit, 50)) do
      fts =
        Enum.map(fts, fn {page, excerpt} ->
          %{
            id: page.id,
            title: page.title,
            slug: page.slug,
            page_type: page.page_type,
            tags: page.tags,
            excerpt: excerpt
          }
        end)

      scored =
        %{}
        |> fuse_rank(fts, k, :excerpt)
        |> fuse_rank(semantic, k, :semantic_distance)

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
      id = item.id
      score = 1.0 / (k + rank)

      existing =
        Map.get(acc, id, %{
          id: id,
          title: item.title,
          slug: item.slug,
          page_type: item.page_type,
          tags: item.tags,
          score: 0.0
        })

      merged =
        existing
        |> Map.put(:score, existing.score + score)
        |> Map.put_new(extra_field, Map.get(item, extra_field))

      Map.put(acc, id, merged)
    end)
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

  # ──────────────────────────────────────────────────────────────────────────
  # Log
  # ──────────────────────────────────────────────────────────────────────────

  @doc "List recent log entries"
  def list_log(opts \\ []) do
    context_id = Keyword.get(opts, :context_id)
    action = Keyword.get(opts, :action)
    limit = Keyword.get(opts, :limit, 50)

    query =
      from l in Log,
        order_by: [desc: l.inserted_at],
        limit: ^limit

    query =
      if context_id do
        where(query, [l], l.context_id == ^context_id)
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

  defp log_action(context_id, action, subject, details) do
    %Log{}
    |> Log.changeset(%{
      context_id: context_id,
      action: action,
      subject: subject,
      details: details
    })
    |> Repo.insert()
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Wikilinks
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Extract [[wikilinks]] from a markdown body.

  Returns a list of `%{slug: "some-slug", display: "Some Slug"}` maps.
  Display text defaults to the slug if not specified.

  ## Formats
  - `[[slug]]` → `%{slug: "slug", display: "slug"}`
  - `[[slug|Display Text]]` → `%{slug: "slug", display: "Display Text"}`

  ## Example

      iex> Dran.Brain.extract_wikilinks("See [[elixir]] and [[phoenix|Phoenix Framework]]")
      [
        %{slug: "elixir", display: "elixir"},
        %{slug: "phoenix", display: "Phoenix Framework"}
      ]
  """
  def extract_wikilinks(body) when is_binary(body) do
    regex = ~r/\[\[([^|\]]+)(?:\|([^\]]+))?\]\]/

    Regex.scan(regex, body)
    |> Enum.map(fn
      [_, slug, display] -> %{slug: String.trim(slug), display: String.trim(display)}
      [_, slug] -> %{slug: String.trim(slug), display: String.trim(slug)}
    end)
    |> Enum.uniq_by(& &1.slug)
  end

  def extract_wikilinks(_), do: []

  @doc """
  Resolve wikilinks in a page's body and create relations for each.

  For each `[[slug]]` found in the body, creates a `related` relation
  from this page to the target page (if it exists in the same context).

  Returns `{created_count, not_found_slugs}`.
  """
  def resolve_wikilinks(%Page{} = page) do
    links = extract_wikilinks(page.body)

    {created, not_found} =
      Enum.reduce(links, {0, []}, fn %{slug: slug}, {acc_created, acc_missing} ->
        target = get_page_by_slug(slug, page.context_id)

        if target && target.id != page.id do
          case create_relation(%{
                 source_id: page.id,
                 target_id: target.id,
                 relation_type: "related"
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
  Extract ![[embeds]] from a markdown body.

  Returns a list of `%{slug: "artifact-slug", display: "alt text"}` maps.
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
        target = get_page_by_slug(slug, page.context_id)

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
  Resolve both wikilinks and embeds, returning a combined result map:

      %{related: {c, missing}, embeds: {c, missing}}
  """
  def resolve_links(%Page{} = page) do
    %{
      related: resolve_wikilinks(page),
      embeds: resolve_embeds(page)
    }
  end

  @doc """
  Fetch embedded artifact pages referenced by `![[slug]]` in a body.

  Returns a map of `slug => %Page{}` for all embeds that resolve to a page
  in the given context. Useful for rendering embedded media in markdown.
  """
  def fetch_embeds(body, context_id) when is_binary(body) and is_binary(context_id) do
    body
    |> extract_embeds()
    |> Enum.map(& &1.slug)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn slug, acc ->
      case get_page_by_slug(slug, context_id) do
        nil -> acc
        page -> Map.put(acc, slug, page)
      end
    end)
  end

  @doc """
  Fetch all wikilink targets from a body, returning a map of
  `slug => %Page{}` for each one that resolves to a page in the
  given context. Slugs that don't resolve are omitted.

  Used by the renderer to know which type-specific URL to emit for
  each `[[slug]]` link (e.g. `/notes/{slug}`, `/concepts/{slug}`).
  """
  def fetch_wikilinks(body, context_id) when is_binary(body) and is_binary(context_id) do
    body
    |> extract_wikilinks()
    |> Enum.map(& &1.slug)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn slug, acc ->
      case get_page_by_slug(slug, context_id) do
        nil -> acc
        page -> Map.put(acc, slug, page)
      end
    end)
  end

  @doc """
  Find all pages in a context whose body references the given slug via
  wikilinks (`[[slug]]`) or embeds (`![[slug]]`).

  Returns a list of `%Page{}` structs (lightweight, without body) that
  link to `slug`. Useful for displaying backlinks on a page detail view.
  """
  def find_backlinks(slug, context_id)
      when is_binary(slug) and is_binary(context_id) do
    link_re = ~r/\[\[(#{Regex.escape(slug)})(?:\|[^\]]+)?\]\]/
    embed_re = ~r/!\[\[(#{Regex.escape(slug)})(?:\|[^\]]+)?\]\]/

    pages = list_pages(context_id: context_id, limit: 10_000, include_body: true)

    pages
    |> Enum.filter(fn page ->
      page.slug != slug and
        (Regex.match?(link_re, page.body || "") or
           Regex.match?(embed_re, page.body || ""))
    end)
    |> Enum.map(fn page ->
      %{page | body: ""}
    end)
  end

  @doc """
  Re-link all wikilinks and embeds across a context when a page's slug changes.

  Finds every page in the context whose body references `old_slug` (via
  `[[old_slug]]`, `[[old_slug|...]]`, `![[old_slug]]`, or `![[old_slug|...]]`)
  and replaces the reference with `new_slug`, preserving any display text.

  Returns `{updated_count, updated_pages}` where `updated_pages` is the list
  of `%Page{}` structs that were changed.
  """
  def relink_wikilinks(context_id, old_slug, new_slug)
      when is_binary(context_id) and is_binary(old_slug) and is_binary(new_slug) do
    if old_slug == new_slug do
      {0, []}
    else
      pages = list_pages(context_id: context_id, limit: 10_000, include_body: true)

      pages
      |> Enum.filter(fn page -> page.slug != old_slug end)
      |> Enum.reduce({0, []}, fn page, {count, updated} ->
        new_body = replace_slug_in_body(page.body, old_slug, new_slug)

        if new_body != page.body do
          case update_page(page, %{body: new_body}) do
            {:ok, updated_page} -> {count + 1, [updated_page | updated]}
            {:error, _} -> {count, updated}
          end
        else
          {count, updated}
        end
      end)
      |> then(fn {count, updated} -> {count, Enum.reverse(updated)} end)
    end
  end

  @doc """
  Replace references to `old_slug` with `new_slug` in a markdown body,
  preserving any display text. Handles both wikilinks and embeds.
  """
  def replace_slug_in_body(body, old_slug, new_slug)
      when is_binary(body) and is_binary(old_slug) and is_binary(new_slug) do
    # Wikilinks: [[old-slug]] and [[old-slug|display]]
    wikilink_pattern = ~r/\[\[(#{Regex.escape(old_slug)})(\|([^\]]+))?\]\]/

    body =
      Regex.replace(wikilink_pattern, body, fn _full, _slug, _pipe_display, display ->
        if display != "" and display != nil do
          "[[#{new_slug}|#{display}]]"
        else
          "[[#{new_slug}]]"
        end
      end)

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

  def replace_slug_in_body(body, _old_slug, _new_slug), do: body

  @doc "Find pages with no inbound relations (orphans)"
  def orphan_pages(context_id) do
    subquery =
      from r in Relation,
        select: r.target_id

    Repo.all(
      from p in Page,
        where: p.context_id == ^context_id and p.id not in subquery(subquery),
        order_by: [asc: p.title],
        select: %{slug: p.slug, title: p.title, page_type: p.page_type, updated_at: p.updated_at}
    )
  end

  @doc "Find broken wikilinks: [[slug]] that don't resolve to any page"
  def broken_wikilinks(context_id) do
    pages = list_pages(context_id: context_id, limit: 10_000, include_body: true)

    Enum.flat_map(pages, fn page ->
      links = extract_wikilinks(page.body)

      Enum.filter(links, fn %{slug: slug} ->
        is_nil(get_page_by_slug(slug, context_id))
      end)
      |> Enum.map(fn %{slug: slug} -> %{page_slug: page.slug, missing_slug: slug} end)
    end)
  end

  @doc "Find stale pages (not updated in X days)"
  def stale_pages(context_id, days \\ 90) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    Repo.all(
      from p in Page,
        where: p.context_id == ^context_id and p.updated_at < ^cutoff,
        order_by: [asc: p.updated_at],
        select: %{slug: p.slug, title: p.title, page_type: p.page_type, updated_at: p.updated_at}
    )
  end

  @doc "Find contested pages (kb_contested = true)"
  def contested_pages(context_id) do
    Repo.all(
      from p in Page,
        where: p.context_id == ^context_id and p.kb_contested == true,
        order_by: [asc: p.title],
        select: %{slug: p.slug, title: p.title, page_type: p.page_type}
    )
  end

  @doc """
  Run a full lint report for a context.

  Returns a map with:
  - `:orphans` — pages with no inbound links
  - `:broken_wikilinks` — `[[slug]]` that don't resolve
  - `:stale` — pages not updated in 90 days
  - `:contested` — pages flagged as contested
  """
  def lint(context_id) do
    %{
      orphans: orphan_pages(context_id),
      broken_wikilinks: broken_wikilinks(context_id),
      stale: stale_pages(context_id),
      contested: contested_pages(context_id)
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
  - `:broken_link_count` — number of broken wikilinks
  - `:total_relations` — number of relations in the context
  """
  def stats(context_id) when is_binary(context_id) do
    pages = list_pages(context_id: context_id, limit: 10_000)

    by_type =
      pages
      |> Enum.group_by(& &1.page_type)
      |> Enum.map(fn {type, list} -> {type, length(list)} end)
      |> Map.new()

    todos_by_status =
      pages
      |> Enum.filter(&(&1.page_type == "todo"))
      |> Enum.group_by(fn p -> (p.meta || %{})["kanban_status"] || "backlog" end)
      |> Enum.map(fn {status, list} -> {status, length(list)} end)
      |> Map.new()

    recent =
      pages
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
      |> Enum.take(5)

    total_relations =
      Repo.aggregate(
        from(r in Relation,
          join: p in assoc(r, :source),
          where: p.context_id == ^context_id
        ),
        :count
      )

    %{
      total_pages: length(pages),
      by_type: by_type,
      recent: recent,
      todos_by_status: todos_by_status,
      orphan_count: length(orphan_pages(context_id)),
      broken_link_count: length(broken_wikilinks(context_id)),
      total_relations: total_relations
    }
  end

  def stats(_), do: %{}
end
