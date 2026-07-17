defmodule Dran.Agent.QA do
  @moduledoc """
  Q&A agent (type "ask"): answers questions using ONLY knowledge already
  present in the brain, then persists the answer as a `query` page.

  Enforces a strict workflow:

    * `search` the brain (delegates to `Brain.search/2`).
    * `get_page` reads a full page by slug from the session context.
    * `create_query_page` persists the synthesized answer as a page of
      `page_type "query"`. At most one query page per session is allowed;
      further attempts return `{:error, "already created"}`.
    * `done` finishes the session.

  The agent never invents information: if no relevant pages are found, it
  must set `answer_status` to `"open"` instead of `"answered"`.
  """

  @behaviour Dran.Agent.Engine.Behaviour

  alias Dran.Brain

  @agent_type "ask"
  @max_search_queries 5

  defmodule State do
    @moduledoc false
    defstruct session: nil,
              module: nil,
              messages: [],
              step: 0,
              pages_created: 0,
              opts: [],
              search_queries: MapSet.new(),
              query_page_created: false
  end

  @doc """
  Start a Q&A session for a question.
  """
  @spec run(String.t(), Ecto.UUID.t(), keyword()) :: {:ok, Dran.Agent.Session.t()}
  def run(question, context_id, opts \\ []) do
    Dran.Agent.Engine.run(__MODULE__, question, context_id, opts)
  end

  @impl true
  def agent_type, do: @agent_type

  @impl true
  def tools do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "search",
          "description" =>
            "Busca páginas existentes en el brain. Devuelve hasta 10 resultados " <>
              "con slug, título, page_type, tags y un excerpt.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "query" => %{
                "type" => "string",
                "description" => "Consulta de búsqueda"
              }
            },
            "required" => ["query"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "get_page",
          "description" =>
            "Lee el contenido completo de una página por su slug dentro del " <>
              "contexto de la sesión. Úsalo en los 2-3 slugs más prometedores " <>
              "de los resultados de search para obtener el cuerpo (body) completo.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "slug" => %{
                "type" => "string",
                "description" => "Slug de la página a leer"
              }
            },
            "required" => ["slug"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "create_query_page",
          "description" =>
            "Crea la página de respuesta (page_type \"query\"). El body DEBE " <>
              "contener la respuesta final citando [slug] de las páginas fuente. " <>
              "Solo se permite UNA página query por sesión.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "title" => %{
                "type" => "string",
                "description" => "Título de la página query"
              },
              "slug" => %{
                "type" => "string",
                "description" => "Slug para la página query"
              },
              "answer" => %{
                "type" => "string",
                "description" => "Cuerpo de la respuesta en markdown, citando [slug]"
              },
              "kind" => %{
                "type" => "string",
                "enum" => Brain.PageMeta.query_kinds(),
                "description" => "Tipo de pregunta (factual, conceptual, how_to, opinion)"
              },
              "difficulty" => %{
                "type" => "string",
                "enum" => Brain.PageMeta.query_difficulties(),
                "description" => "Dificultad (simple, intermediate, advanced)"
              },
              "answer_status" => %{
                "type" => "string",
                "enum" => Brain.PageMeta.query_statuses(),
                "description" =>
                  "Estado de la respuesta. \"answered\" si se encontró información, " <>
                  "\"open\" si no había páginas relevantes."
              },
              "tags" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "Tags opcionales"
              }
            },
            "required" => ["title", "answer"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "done",
          "description" => "Finaliza la sesión Q&A con un resumen breve.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "summary" => %{
                "type" => "string",
                "description" => "Resumen corto de la respuesta"
              }
            },
            "required" => ["summary"]
          }
        }
      }
    ]
  end

  @impl true
  def system_prompt(opts \\ []) do
    lang = lang_code(opts)
    lang_name = lang_name(lang)

    """
    Eres un agente Q&A para Dran. Respondes preguntas USANDO ÚNICAMENTE el
    conocimiento que ya existe en el brain. Nunca inventas información ni
    usas conocimiento externo.

    Idioma: responde SIEMPRE en #{lang_name} (#{lang}), el mismo idioma de
    la pregunta del usuario.

    Workflow obligatorio:
    1. Llama a `search` con 2-3 queries distintas y variadas sobre la
       pregunta. Planifica las queries de antemano; no repitas queries.
    2. De los resultados, selecciona los 2-3 slugs más relevantes y llama
       a `get_page` para leer su contenido completo.
    3. Sintetiza la respuesta basándote en el contenido leído. Cita las
       páginas fuente usando [slug] en el cuerpo de la respuesta.
       Si hay información suficiente, procede al paso 4 con
       answer_status "answered".
    4. Llama a `create_query_page` con la respuesta final en `answer`.
       El body debe contener la respuesta en markdown citando [slug].
       Máximo UNA página query por sesión.
    5. Llama a `done` con un resumen breve.

    Reglas estrictas:
    - Si tras buscar NO encuentras páginas relevantes, crea la página query
      con answer_status "open" y un body explicando que no se encontró
      información suficiente en el brain. NO inventes una respuesta.
    - Nunca uses conocimiento que no provenga de las páginas leídas.
    - Si una búsqueda no devuelve resultados útiles, prueba otra query
      distinta antes de declarar "open".
    - Cita siempre: incluye [slug] junto a cada afirmación clave.
    - Respeta el límite de una página query por sesión; si ya creaste una,
      pasa directamente a `done`.
    """
  end

  defp lang_code(opts) do
    case Keyword.get(opts, :lang) do
      nil -> "es"
      lang when is_binary(lang) -> lang
      _ -> "es"
    end
  end

  defp lang_name("es"), do: "español"
  defp lang_name("en"), do: "inglés"
  defp lang_name("fr"), do: "francés"
  defp lang_name("de"), do: "alemán"
  defp lang_name("pt"), do: "portugués"
  defp lang_name("it"), do: "italiano"
  defp lang_name("ja"), do: "japonés"
  defp lang_name("zh"), do: "chino"
  defp lang_name(_), do: "español"

  @impl true
  def build_messages(input, session, opts \\ []) do
    [
      %{"role" => "system", "content" => system_prompt(opts)},
      %{"role" => "user", "content" => "Pregunta: #{input}\nSession: #{session.id}"}
    ]
  end

  @impl true
  def init_state(session, module, opts) do
    %State{
      session: session,
      module: module,
      messages: build_messages(session.input, session, opts),
      step: 0,
      pages_created: 0,
      opts: opts,
      search_queries: MapSet.new(),
      query_page_created: false
    }
  end

  # ── Tool: search ───────────────────────────────────────────────────────────

  @impl true
  def execute_tool("search", args, %State{} = state) do
    query = String.trim(args["query"] || "")

    cond do
      query == "" ->
        {{:error, "empty query"}, state}

      MapSet.member?(state.search_queries, query) ->
        previous = MapSet.to_list(state.search_queries) |> Enum.take(10)

        {{:error,
          "Ya buscaste '#{query}'. No repitas queries. " <>
            "Queries previas: #{Enum.join(previous, ", ")}. " <>
            "Usa otro enfoque o pasa a get_page / create_query_page."}, state}

      MapSet.size(state.search_queries) >= @max_search_queries ->
        {{:error,
          "Has usado las #{@max_search_queries} búsquedas permitidas. " <>
            "Pasa a get_page y luego create_query_page."}, state}

      true ->
        result =
          Brain.search(query, context_id: state.session.context_id, limit: 10)

        new_state = %{state | search_queries: MapSet.put(state.search_queries, query)}
        {result, new_state}
    end
  end

  # ── Tool: get_page ─────────────────────────────────────────────────────────

  @impl true
  def execute_tool("get_page", args, %State{} = state) do
    slug = String.trim(args["slug"] || "")

    if slug == "" do
      {{:error, "empty slug"}, state}
    else
      case Brain.get_page_by_slug(slug, state.session.context_id) do
        nil ->
          {{:error, "page '#{slug}' not found in context"}, state}

        page ->
          data = %{
            slug: page.slug,
            title: page.title,
            page_type: page.page_type,
            body: page.body,
            tags: page.tags || [],
            meta: page.meta || %{}
          }

          {{:ok, data}, state}
      end
    end
  end

  # ── Tool: create_query_page ────────────────────────────────────────────────

  @impl true
  def execute_tool("create_query_page", args, %State{} = state) do
    if state.query_page_created do
      {{:error, "already created"}, state}
    else
      answer = args["answer"] || ""
      answer_status = args["answer_status"] || "answered"

      meta =
        %{
          "kind" => args["kind"] || "factual",
          "difficulty" => args["difficulty"] || "intermediate",
          "answer_status" => answer_status,
          "answered_by" => "qa-agent",
          "agent_session_id" => state.session.id
        }

      page_attrs = %{
        context_id: state.session.context_id,
        title: args["title"],
        slug: args["slug"],
        body: answer,
        page_type: "query",
        tags: args["tags"] || [],
        created_by: "qa-agent",
        owner: "qa-agent",
        meta: meta
      }

      case Brain.create_page(page_attrs) do
        {:ok, page} ->
          Phoenix.PubSub.broadcast(
            Dran.PubSub,
            "agents:#{state.session.id}",
            {:page_created, page}
          )

          {{:ok, %{slug: page.slug, id: page.id, title: page.title}},
           %{state | pages_created: state.pages_created + 1, query_page_created: true}}

        {:error, cs} ->
          {{:error, format_changeset_errors(cs)}, state}
      end
    end
  end

  # ── Tool: done ─────────────────────────────────────────────────────────────

  @impl true
  def execute_tool("done", _args, %State{} = state), do: {{:ok, :done}, state}

  @impl true
  def execute_tool(_tool, _args, %State{} = state), do: {{:error, :unknown_tool}, state}

  # ── summarize_result ───────────────────────────────────────────────────────

  @impl true
  def summarize_result({:ok, pages}) when is_list(pages) do
    %{status: "ok", count: length(pages), data: pages}
  end

  def summarize_result({:ok, %{slug: slug, title: title} = page}) do
    summary = %{status: "ok", slug: slug, title: title}

    case Map.get(page, :body) do
      nil -> summary
      body -> Map.put(summary, :body, String.slice(body, 0, 500))
    end
  end

  def summarize_result({:ok, :done}), do: %{status: "done"}

  def summarize_result({:error, reason}) when is_binary(reason) do
    %{status: "error", error: reason}
  end

  def summarize_result({:error, reason}), do: %{status: "error", error: inspect(reason)}

  # ── gathered_summary ──────────────────────────────────────────────────────

  @impl true
  def gathered_summary(%State{search_queries: queries}) do
    if MapSet.size(queries) == 0 do
      "No has buscado todavía. Usa search con 2-3 queries distintas, luego get_page " <>
        "en los slugs relevantes y finalmente create_query_page + done."
    else
      list = MapSet.to_list(queries) |> Enum.take(10)

      "Búsquedas realizadas (#{length(list)}):\n" <>
        Enum.map_join(list, "\n", &"- #{&1}") <>
        "\n\nSintetiza la respuesta con create_query_page y luego llama done."
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, val}, acc ->
        String.replace(acc, "%{#{key}}", to_string(val))
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end
end
