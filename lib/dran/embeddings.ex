defmodule Dran.Embeddings do
  @moduledoc """
  Orchestrates embedding generation and storage for pages.

  - `text_for_page/1` builds the indexable text.
  - `hash_text/1` fingerprints it so we only re-embed when content changes.
  - `schedule/1` triggers generation (async by default).
  - `generate/1` does it synchronously.

  Generation is skipped when inference is not configured or when the page
  already has a matching embedding_hash.
  """

  alias Dran.Repo
  alias Dran.Brain.Page
  alias Dran.Inference

  @doc """
  Build the text used to compute a page embedding.
  """
  @spec text_for_page(Page.t()) :: String.t()
  def text_for_page(%Page{} = page) do
    parts = [
      page.title,
      page.summary,
      page.body,
      Enum.join(page.tags || [], " ")
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Hash of the indexable text, used to skip re-generation.
  """
  @spec hash_text(String.t()) :: String.t()
  def hash_text(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  @doc """
  True if the page needs a new embedding.
  """
  @spec needs_embedding?(Page.t()) :: boolean()
  def needs_embedding?(%Page{embedding_hash: nil}), do: true

  def needs_embedding?(%Page{} = page) do
    page.embedding_hash != hash_text(text_for_page(page))
  end

  @doc """
  Schedule embedding generation for a page.

  By default it runs asynchronously under `Dran.Embeddings.TaskSupervisor`.
  Set `Application.put_env(:dran, :inference, schedule_async: false)` to run
  synchronously (useful in tests and backfill scripts).
  """
  @spec schedule(Page.t()) :: :ok | :ignored
  def schedule(%Page{} = page) do
    cond do
      not Inference.enabled?() ->
        :ignored

      not needs_embedding?(page) ->
        :ignored

      schedule_async?() ->
        Task.Supervisor.start_child(
          Dran.Embeddings.TaskSupervisor,
          fn -> generate(page) end,
          restart: :transient
        )

        :ok

      true ->
        generate(page)
        :ok
    end
  end

  @doc """
  Generate and store an embedding for the given page synchronously.

  Returns `{:ok, Page.t()}` or `{:error, term()}`.
  """
  @spec generate(Page.t()) :: {:ok, Page.t()} | {:error, term()}
  def generate(%Page{} = page) do
    text = text_for_page(page)
    new_hash = hash_text(text)

    if page.embedding_hash == new_hash do
      {:ok, page}
    else
      case Inference.embed(text) do
        {:ok, vector} ->
          page
          |> Ecto.Changeset.change(
            embedding_hash: new_hash,
            embedding: Pgvector.new(vector)
          )
          |> Repo.update()

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Update all pages in a context that need embeddings. Useful for backfill.
  """
  @spec backfill_pages(Dran.Brain.Context.t() | binary(), keyword()) ::
          {non_neg_integer(), list(term())}
  def backfill_pages(context_or_slug, opts \\ [])

  def backfill_pages(slug, opts) when is_binary(slug) do
    context = Dran.Brain.get_context_by_slug(slug) || raise "context not found: #{slug}"
    backfill_pages(context, opts)
  end

  def backfill_pages(%Dran.Brain.Context{id: context_id}, opts) do
    import Ecto.Query

    async = Keyword.get(opts, :async, schedule_async?())

    page_ids =
      Repo.all(
        from p in Page,
          where: p.context_id == ^context_id and is_nil(p.embedding),
          select: p.id
      )

    pages = Repo.all(from p in Page, where: p.id in ^page_ids)

    if async do
      Enum.each(pages, fn page ->
        Task.Supervisor.start_child(
          Dran.Embeddings.TaskSupervisor,
          fn -> generate(page) end,
          restart: :transient
        )
      end)

      {length(pages), []}
    else
      results = Enum.map(pages, &generate/1)

      failures =
        Enum.filter(results, fn
          {:error, _} -> true
          _ -> false
        end)

      {length(pages) - length(failures), failures}
    end
  end

  defp schedule_async? do
    Dran.Inference.Config.config()
    |> Kernel.||(schedule_async: true)
    |> Keyword.get(:schedule_async, true)
  end
end
