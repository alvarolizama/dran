defmodule Dran.Slug do
  @moduledoc """
  Shared slug utilities for the Dran knowledge base.

  Provides slugification, unique slug generation, and uniqueness enforcement
  within a context.
  """

  alias Dran.Brain

  @doc """
  Convert a string to a URL-safe slug.

  Lowercases, replaces runs of non-alphanumeric characters with hyphens,
  and trims leading/trailing hyphens. Returns an empty string for `nil`
  or inputs that produce no usable characters.
  """
  @spec slugify(binary() | nil) :: binary()
  def slugify(nil), do: ""
  def slugify(""), do: ""

  def slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.replace(~r/^-+|-+$/, "")
  end

  @doc """
  Generate a unique slug from a title within a context.

  Slugifies `title`, falls back to `fallback_type` if the result is empty,
  then ensures the slug is unique within the given context.
  """
  @spec generate(binary() | nil, binary() | nil, binary()) :: binary()
  def generate(title, context_id, fallback_type) do
    base = slugify(title)
    base = if base == "", do: fallback_type, else: base
    ensure_unique(base, context_id, 0)
  end

  @doc """
  Ensure a slug is unique within a context.

  Appends a random hex suffix if the base slug is already taken.
  `attempt` should start at 0.
  """
  @spec ensure_unique(binary(), binary() | nil, non_neg_integer()) :: binary()
  def ensure_unique(base, context_id, attempt) do
    slug = candidate_slug(base, attempt)

    if Brain.get_page_by_slug(slug, context_id) do
      ensure_unique(base, context_id, attempt + 1)
    else
      slug
    end
  end

  @doc """
  Ensure a slug is unique within a context, allowing the original slug.

  Like `ensure_unique/3`, but permits the candidate to match `original_slug`
  (the slug of the page being renamed).
  """
  @spec ensure_unique(binary(), binary() | nil, binary(), non_neg_integer()) :: binary()
  def ensure_unique(base, context_id, original_slug, attempt) do
    slug = candidate_slug(base, attempt)

    if slug == original_slug or is_nil(Brain.get_page_by_slug(slug, context_id)) do
      slug
    else
      ensure_unique(base, context_id, original_slug, attempt + 1)
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
