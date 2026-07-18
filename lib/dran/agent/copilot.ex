defmodule Dran.Agent.Copilot do
  @moduledoc """
  Copilot agent: answers user questions by searching and reading pages
  from the second brain using MCP tools via the Agent.Engine ReAct loop.

  Unlike the batch agents (research, curator), the copilot is conversational:
  it receives the chat history and the current page slug, and can call
  any of the 18 MCP tools to gather information before answering.

  The copilot is stateless per message: each user message starts a new
  Agent.Session. The chat history (last 10 messages) is passed in
  `session.meta["history"]` so the LLM has context, but tool state is
  not preserved between messages.

  ## Tools

  The copilot exposes all 18 MCP tools (converted to OpenAI function-calling
  format) plus a `done` tool that the engine requires to finish the session.
  The LLM chooses which tools to call based on the user's question.

  ## Context Injection

  Most MCP tools require a `"context"` parameter (the context slug). The
  copilot automatically injects this from `session.meta["context_slug"]`
  if the LLM didn't include it in the tool arguments, defaulting to
  `"personal"`.
  """

  @behaviour Dran.Agent.Engine.Behaviour

  alias Dran.MCP

  @agent_type "copilot"

  defmodule State do
    @moduledoc false
    defstruct session: nil,
              module: nil,
              messages: [],
              step: 0,
              pages_created: 0,
              opts: [],
              sources: []
  end

  # ── Convenience ───────────────────────────────────────────────────────────

  @doc """
  Start a copilot agent session.

  Pass `meta: %{context_slug: "...", history: [...], page_slug: "..."}`
  in opts so the copilot knows which context to search and what the
  conversation history is.
  """
  @spec run(String.t(), Ecto.UUID.t(), keyword()) :: {:ok, Dran.Agent.Session.t()}
  def run(input, context_id, opts \\ []) do
    Dran.Agent.Engine.run(__MODULE__, input, context_id, opts)
  end

  # ── Behaviour callbacks ───────────────────────────────────────────────────

  @impl true
  def agent_type, do: @agent_type

  @impl true
  def tools do
    # Convert MCP tool schemas to OpenAI function-calling format,
    # then append the `done` tool that the engine requires to finish.
    mcp_tools =
      MCP.tool_schemas()
      |> Enum.map(fn schema ->
        %{
          "type" => "function",
          "function" => %{
            "name" => schema["name"],
            "description" => schema["description"],
            "parameters" => schema["inputSchema"]
          }
        }
      end)

    mcp_tools ++ [done_tool()]
  end

  @impl true
  def system_prompt do
    """
    Eres el copiloto de un segundo cerebro (second brain). El usuario te hace
    preguntas y tú usas las herramientas disponibles para buscar información
    en su base de conocimiento.

    Reglas:
    - Usa `dran_search` primero para encontrar páginas relevantes.
    - Usa `dran_get_page` para leer el contenido completo de una página.
    - Usa `dran_get_links` para explorar relaciones entre páginas.
    - Usa `dran_list_pages` para listar páginas por tipo (goal, plan, todo).
    - Usa `dran_get_stats` para estadísticas del contexto.
    - Cuando tengas suficiente información, responde con `done` y el campo `summary`.
    - Cita las fuentes como [slug] al final de las afirmaciones relevantes.
    - Responde en español, de forma clara y concisa.
    - Si no encuentras información, dilo honestamente.
    """
  end

  @impl true
  def build_messages(input, session) do
    history = get_in(session.meta, ["history"]) || []

    history_msgs =
      history
      |> Enum.take(-10)
      |> Enum.map(fn msg ->
        %{"role" => msg["role"] || "user", "content" => msg["content"] || ""}
      end)

    context_slug = get_in(session.meta, ["context_slug"]) || "personal"
    page_slug = get_in(session.meta, ["page_slug"])

    system = system_prompt() <> "\nContexto actual: #{context_slug}"
    system = if page_slug, do: system <> "\nPágina actual: #{page_slug}", else: system

    [%{"role" => "system", "content" => system}] ++
      history_msgs ++
      [%{"role" => "user", "content" => input}]
  end

  @impl true
  def init_state(session, module, opts) do
    messages = build_messages(session.input, session)

    %State{
      session: session,
      module: module,
      messages: messages,
      step: 0,
      pages_created: 0,
      opts: opts,
      sources: []
    }
  end

  @impl true
  def execute_tool("done", _args, %State{} = state) do
    {{:ok, :done}, state}
  end

  def execute_tool(tool, args, %State{} = state) do
    args = args || %{}

    # Inject context_slug into args if missing (from session.meta)
    args = inject_context(args, state)

    # Call the MCP tool via the public process_message API
    msg = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => 1,
      "params" => %{"name" => tool, "arguments" => args}
    }

    case MCP.process_message(msg) do
      %{"result" => %{"content" => [%{"text" => text} | _]}} ->
        if String.starts_with?(text, "Error:") do
          {{:error, text}, state}
        else
          sources = extract_sources(text, state.sources)
          {{:ok, text}, %{state | sources: sources}}
        end

      %{"error" => %{"message" => reason}} ->
        {{:error, reason}, state}

      _ ->
        {{:error, "unexpected MCP response"}, state}
    end
  end

  @impl true
  def summarize_result({:ok, :done}), do: %{status: "done"}

  def summarize_result({:ok, text}) when is_binary(text) do
    %{status: "ok", data: text, length: String.length(text)}
  end

  def summarize_result({:error, reason}) when is_binary(reason) do
    %{status: "error", error: reason}
  end

  def summarize_result({:error, reason}) do
    %{status: "error", error: inspect(reason)}
  end

  def summarize_result(other), do: %{status: "other", result: inspect(other)}

  @impl true
  def gathered_summary(%State{} = state) do
    "Steps: #{state.step}, sources gathered: #{length(state.sources)}"
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp done_tool do
    %{
      "type" => "function",
      "function" => %{
        "name" => "done",
        "description" => "Finish the copilot session with a summary answer to the user.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "summary" => %{
              "type" => "string",
              "description" => "The final answer to the user's question"
            }
          },
          "required" => ["summary"]
        }
      }
    }
  end

  defp inject_context(args, %State{} = state) do
    if Map.has_key?(args, "context") do
      args
    else
      context_slug = get_in(state.session.meta, ["context_slug"]) || "personal"
      Map.put(args, "context", context_slug)
    end
  end

  defp extract_sources(result, existing) do
    # Extract slugs from tool results (backtick-wrapped) for citation tracking
    slugs =
      Regex.scan(~r/`([a-z0-9][a-z0-9\-]*)`/, result, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    (existing ++ slugs) |> Enum.uniq()
  end
end
