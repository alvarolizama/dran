defmodule Dran.Slug do
  @moduledoc """
  Shared slug utilities for the Dran knowledge base.

  Provides slugification, unique slug generation, and uniqueness enforcement
  within a context.
  """

  alias Dran.Knowledge

  @doc """
  Convert a string to a URL-safe slug.

  Normalizes Unicode (NFD) to decompose accented characters, drops the
  resulting combining marks (non-ASCII), lowercases, replaces runs of
  non-alphanumeric characters with hyphens, and trims leading/trailing
  hyphens. Inputs that produce no usable characters (empty, whitespace,
  punctuation-only, `nil`, or non-binaries) fall back to `"untitled"`.
  """
  @spec slugify(binary() | term()) :: binary()
  def slugify(text) when is_binary(text) do
    slug =
      text
      |> String.normalize(:nfd)
      |> String.replace(~r/[\x80-\xFF]/, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.replace(~r/^-+|-+$/, "")

    if slug == "", do: "untitled", else: slug
  end

  def slugify(_), do: "untitled"

  @doc """
  Convert a slug back into a human-readable title.

  Splits on hyphens, capitalizes each word, and joins with spaces.
  `"sales-team"` becomes `"Sales Team"`.
  """
  @spec titleize(binary()) :: binary()
  def titleize(slug) do
    slug
    |> String.split("-")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  @doc """
  Generate a unique slug from a title within a context.

  Slugifies `title`, falls back to `fallback_type` if the result is empty,
  then ensures the slug is unique within the given context.
  """
  @spec generate(binary() | nil, binary() | nil, binary()) :: binary()
  def generate(title, workspace_id, fallback_type) do
    base = base_from_title(title, fallback_type)

    ensure_unique(base, fn candidate ->
      Knowledge.get_page_by_slug(candidate, workspace_id) != nil
    end)
  end

  @doc """
  Slugify a title with a fallback when it produces nothing usable.

  Unlike `slugify/1` (which falls back to `"untitled"`), this is the base
  for auto-managed slugs: an empty/punctuation-only title yields
  `fallback` (the resource type), never `"untitled"`, so two unnamed
  resources of different kinds don't collide on the same base.
  """
  @spec base_from_title(binary() | term(), binary()) :: binary()
  def base_from_title(title, fallback) do
    case slugify(title) do
      "untitled" -> fallback
      "" -> fallback
      slug -> slug
    end
  end

  @doc """
  Ensure `base` is unique against a `taken?` predicate.

  Context-agnostic counterpart to `ensure_unique/3,4` (which are wired to
  `Knowledge.get_page_by_slug`). The caller passes a 1-arity `taken?` that
  returns true when a candidate slug already exists in its scope — and, for
  updates, closes over the record's own slug so it is NOT treated as taken.

  Attempt 0 returns `base` as-is; later attempts append a random hex suffix.
  """
  @spec ensure_unique(binary(), (binary() -> boolean()), non_neg_integer()) :: binary()
  def ensure_unique(base, taken?, attempt \\ 0) when is_function(taken?, 1) do
    slug = candidate_slug(base, attempt)
    if taken?.(slug), do: ensure_unique(base, taken?, attempt + 1), else: slug
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Auto-managed slugs — the shared create/update policy for every context
  # (pages, goals, tasks, workflows, steps, collections).
  #
  #   * An explicit non-blank `slug` in attrs ALWAYS wins (API/MCP/seeds).
  #   * Create without slug → derived from the title (or `:name`) field,
  #     suffixed with a random hex while `taken?` reports a collision.
  #   * Update → the slug is regenerated ONLY when the title changed AND no
  #     explicit slug arrived AND `sync_slug` is not disabled. Uniqueness
  #     excludes the record itself (via `lookup` returning a struct with :id).
  #   * `"sync_slug" => false` in attrs opts out of regeneration (used by
  #     the page editor's keystroke autosave to avoid slug churn).
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Inject an auto-managed slug into CREATE attrs (string or atom keys).

  `opts`:
    * `:field` — the source field for the base (default `"title"`)
    * `:fallback` — base when the field produces nothing (default `"untitled"`)
    * `:taken?` — 1-arity predicate, true when a candidate slug exists
  """
  @spec inject_create(map(), keyword()) :: map()
  def inject_create(attrs, opts) when is_map(attrs) do
    field = Keyword.get(opts, :field, "title")
    fallback = Keyword.get(opts, :fallback, "untitled")
    taken? = Keyword.fetch!(opts, :taken?)

    case explicit_slug(attrs) do
      slug when is_binary(slug) ->
        put_slug(attrs, slug)

      nil ->
        base = base_from_title(fetch_attr(attrs, field), fallback)
        put_slug(attrs, ensure_unique(base, taken?))
    end
  end

  @doc """
  Inject an auto-managed slug into UPDATE attrs (string or atom keys).

  `opts` (same as `inject_create/2`) plus:
    * `:lookup` — 1-arity fn slug → record-with-:id | nil, scoped so that
      only OTHER records count as taken
    * `:record` — the struct being updated (its title/id drive the policy)
  """
  @spec inject_update(map(), struct(), keyword()) :: map()
  def inject_update(attrs, record, opts) when is_map(attrs) and is_struct(record) do
    field = Keyword.get(opts, :field, "title")
    fallback = Keyword.get(opts, :fallback, "untitled")
    lookup = Keyword.fetch!(opts, :lookup)
    new_title = fetch_attr(attrs, field)

    cond do
      slug = explicit_slug(attrs) ->
        put_slug(attrs, slug)

      sync_slug_disabled?(attrs) ->
        attrs

      title_changed?(record, new_title, field) ->
        taken? = fn candidate ->
          case lookup.(candidate) do
            nil -> false
            %{id: id} -> id != record.id
          end
        end

        base = base_from_title(new_title, fallback)
        put_slug(attrs, ensure_unique(base, taken?))

      true ->
        attrs
    end
  end

  @doc """
  Fetch an attr by string key with atom-key fallback. Keys passed here are
  compile-time literals of this module's callers ("slug", "title", "name",
  "workspace_id"), never user input.
  """
  @spec fetch_attr(map(), binary()) :: term()
  def fetch_attr(attrs, key) when is_map(attrs) and is_binary(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        value

      :error ->
        try do
          Map.get(attrs, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end
    end
  end

  # Explicit slug = present (string or atom key) and non-blank.
  defp explicit_slug(attrs) do
    case fetch_attr(attrs, "slug") do
      slug when is_binary(slug) ->
        trimmed = String.trim(slug)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp sync_slug_disabled?(attrs), do: fetch_attr(attrs, "sync_slug") == false

  defp title_changed?(record, new_title, field) do
    is_binary(new_title) and String.trim(new_title) != "" and
      new_title != Map.get(record, String.to_existing_atom(field))
  end

  # Inject the slug preserving the attrs' key shape so `cast/3` sees it
  # under the same convention the caller used.
  defp put_slug(attrs, slug) do
    cond do
      Map.has_key?(attrs, "slug") -> Map.put(attrs, "slug", slug)
      Map.has_key?(attrs, :slug) -> Map.put(attrs, :slug, slug)
      # No slug key yet: follow the title/name key shape when present.
      Map.has_key?(attrs, :title) or Map.has_key?(attrs, :name) -> Map.put(attrs, :slug, slug)
      true -> Map.put(attrs, "slug", slug)
    end
  end

  # Build a candidate slug from a base and attempt number.
  # Attempt 0 returns the base as-is; later attempts append a random hex suffix.
  defp candidate_slug(base, 0), do: base

  defp candidate_slug(base, attempt) when is_integer(attempt) and attempt > 0 do
    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    "#{base}-#{suffix}"
  end
end
