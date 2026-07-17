defmodule Dran.Chat.Brain do
  @moduledoc """
  The chat brain — answers user questions using the second brain's pages.

  Given a question and a context, it searches the brain for relevant pages,
  builds a system prompt with their content, and calls the inference server
  to generate an answer that cites sources as `[slug]`.

  ## Current-page shortcut

  If `opts[:current_page]` is set and the question references the current
  page ("esta página", "esta nota", "este concepto", "aquí", "esto"),
  the brain skips search and uses that page directly.
  """

  alias Dran.{Brain, Inference}
  alias Dran.Brain.Page

  @max_page_chars 2000
  @max_pages 3

  @type source :: %{
          String.t() => String.t()
        }

  @doc """
  Answer a question using the second brain.

  ## Options

  - `:current_page` — slug of the page the user is currently viewing. If the
    question references "this page" / "esta nota" / etc., that page is used
    directly without searching.
  """
  @spec answer(String.t(), String.t(), list(map()), keyword()) ::
          {:ok, String.t(), [source()]} | {:error, term()}
  def answer(context_id, question, history, opts \\ []) do
    current_page = Keyword.get(opts, :current_page)

    cond do
      not Inference.enabled?() ->
        {:ok, not_configured_message(), []}

      true ->
        case resolve_pages(context_id, question, current_page) do
          {:ok, []} ->
            {:ok, no_results_message(), []}

          {:ok, pages} ->
            answer_with_pages(context_id, question, history, pages)
        end
    end
  end

  # ── Page resolution ──────────────────────────────────────────────────────

  defp resolve_pages(context_id, question, current_page) do
    if current_page && references_current_page?(question) do
      case Brain.get_page_by_slug(current_page, context_id) do
        nil -> {:ok, []}
        page -> {:ok, [page]}
      end
    else
      search_pages(context_id, question)
    end
  end

  defp references_current_page?(question) do
    down = String.downcase(question)

    [
      "esta página",
      "esta pagina",
      "esta nota",
      "este concepto",
      "este documento",
      "aquí",
      "aqui",
      "esto",
      "esta entrada"
    ]
    |> Enum.any?(&String.contains?(down, &1))
  end

  defp search_pages(context_id, question) do
    case Brain.search(question, context_id: context_id, limit: @max_pages) do
      {:ok, results} ->
        pages =
          results
          |> Enum.take(@max_pages)
          |> Enum.map(&fetch_full_page(&1, context_id))
          |> Enum.reject(&is_nil/1)

        {:ok, pages}

      {:error, _} ->
        {:ok, []}
    end
  end

  defp fetch_full_page(result, _context_id) do
    case result do
      %Page{} = page -> page
      %{id: id} when is_binary(id) -> Brain.get_page(id)
      _ -> nil
    end
  end

  # ── LLM call ─────────────────────────────────────────────────────────────

  defp answer_with_pages(_context_id, question, history, pages) do
    sources = build_sources(pages)
    system_prompt = build_system_prompt(pages)
    messages = build_messages(system_prompt, history, question)

    payload = %{
      "model" => Inference.chat_model(),
      "messages" => messages,
      "temperature" => 0.3,
      "max_tokens" => 800
    }

    case Inference.chat(payload) do
      {:ok, %{"content" => content}} when is_binary(content) ->
        {:ok, content, sources}

      {:ok, %{"message" => %{"content" => content}}} when is_binary(content) ->
        {:ok, content, sources}

      {:ok, response} ->
        content = extract_content(response)
        {:ok, content, sources}

      {:error, _reason} ->
        {:ok, error_message(), sources}
    end
  end

  defp extract_content(response) do
    response
    |> get_in(["message", "content"])
    |> case do
      nil -> Map.get(response, "content", "")
      content -> content
    end
  end

  # ── Prompt building ──────────────────────────────────────────────────────

  defp build_sources(pages) do
    Enum.map(pages, fn page ->
      %{"slug" => page.slug, "title" => page.title}
    end)
  end

  defp build_system_prompt(pages) do
    pages_text =
      pages
      |> Enum.map(fn page ->
        body = page.body || ""
        truncated = String.slice(body, 0, @max_page_chars)

        """
        ## [#{page.slug}] — #{page.title}

        #{truncated}
        """
      end)
      |> Enum.join("\n")

    """
    Eres un asistente que responde preguntas basándote en una base de conocimiento personal (second brain).

    Solo debes usar la información de las páginas proporcionadas abajo. No inventes datos que no estén en las páginas.

    Cita las fuentes usando el formato [slug] al final de las afirmaciones relevantes, por ejemplo: "Elixir es funcional [elixir]".

    Responde en español, en un máximo de 3 párrafos, de forma clara y concisa.

    ## Páginas de referencia

    #{pages_text}
    """
  end

  defp build_messages(system_prompt, history, question) do
    history_msgs =
      history
      |> Enum.take(-10)
      |> Enum.map(fn msg ->
        role = msg["role"] || msg[:role] || "user"
        content = msg["content"] || msg[:content] || ""
        %{"role" => role, "content" => content}
      end)

    [%{"role" => "system", "content" => system_prompt}] ++
      history_msgs ++
      [%{"role" => "user", "content" => question}]
  end

  # ── Fallback messages ─────────────────────────────────────────────────────

  defp not_configured_message do
    "El servidor de inferencia no está configurado. " <>
      "Configura DRAN_INFERENCE_API_URL para activar el chat."
  end

  defp no_results_message do
    "No encontré nada relevante en tu base de conocimiento para esa pregunta. " <>
      "Intenta reformularla o agrega más páginas al contexto."
  end

  defp error_message do
    "Ocurrió un error al generar la respuesta. Intenta de nuevo."
  end
end
