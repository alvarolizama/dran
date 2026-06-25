defmodule Dran.Agent.Engine do
  @moduledoc """
  Generic ReAct engine for Dran agents.

  `run(module, input, context_id, opts)` creates a session, then spawns the
  loop on `Dran.Relations.TaskSupervisor`. The supplied `module` must implement
  the `Dran.Agent.Engine.Behaviour` callbacks.

  Each step is persisted and broadcasted via `Dran.PubSub` on
  `agents:<session_id>` and `agents:all`.

  Running tasks are registered in `Dran.Agent.SessionRegistry` under the
  session id so they can be cancelled with `cancel/1`.
  """

  require Logger
  import Ecto.Query

  alias Dran.{Inference, Repo}
  alias Dran.Agent.{Session, Step}

  @max_steps 15
  @per_step_timeout 120_000
  @max_tool_result_chars 2_000
  @max_completion_tokens 4_096

  @doc """
  Start an agent session and spawn the ReAct loop asynchronously.

  Returns `{:ok, session}` immediately. The caller can subscribe to
  `Dran.PubSub` topics or poll the session in the database.
  """
  @spec run(module(), String.t(), Ecto.UUID.t(), keyword()) :: {:ok, Session.t()}
  def run(module, input, context_id, opts \\ []) do
    session = create_session!(module, input, context_id, opts)

    Task.Supervisor.start_child(Dran.Relations.TaskSupervisor, fn ->
      register_runner(session.id)

      try do
        execute_loop(module, session, opts)
      after
        unregister_runner(session.id)
      end
    end)

    {:ok, session}
  end

  @doc """
  Cancel a running agent session.

  Sends a graceful shutdown to the task. If the session is already done or
  the runner is gone, it updates the session to `"cancelled"`.
  """
  @spec cancel(Ecto.UUID.t()) :: :ok | {:error, :not_found}
  def cancel(session_id) do
    case Registry.lookup(Dran.Agent.SessionRegistry, session_id) do
      [{pid, _} | _] ->
        Process.exit(pid, :shutdown)
        mark_cancelled!(session_id)
        :ok

      [] ->
        case Repo.get(Session, session_id) do
          nil ->
            {:error, :not_found}

          %{status: "running"} ->
            mark_cancelled!(session_id)
            :ok

          _ ->
            :ok
        end
    end
  end

  defp register_runner(session_id) do
    Registry.register(Dran.Agent.SessionRegistry, session_id, nil)
  end

  defp unregister_runner(session_id) do
    Registry.unregister(Dran.Agent.SessionRegistry, session_id)
  end

  defp mark_cancelled!(session_id) do
    Repo.get!(Session, session_id)
    |> Session.changeset(%{
      status: "cancelled",
      summary: "Agent session was cancelled by the user.",
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update!()
  end

  defp create_session!(module, input, context_id, opts) do
    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        agent_type: module.agent_type(),
        input: input,
        context_id: context_id,
        status: "running",
        started_at: DateTime.utc_now() |> DateTime.truncate(:second),
        meta: %{model: Inference.chat_model(), opts: opts}
      })
      |> Repo.insert()

    session
  end

  defp execute_loop(module, %Session{} = session, opts) do
    state = %{
      session: session,
      module: module,
      messages: module.build_messages(session.input, session),
      step: 0,
      pages_created: 0,
      opts: opts
    }

    loop(state)
  end

  defp loop(%{step: step} = state) when step >= @max_steps do
    finish_session(state, %{"summary" => "Agent reached max steps (#{@max_steps})"})
    :ok
  end

  defp loop(state) do
    task =
      Task.Supervisor.async_nolink(Dran.Relations.TaskSupervisor, fn ->
        single_turn(state)
      end)

    case Task.yield(task, @per_step_timeout) do
      nil ->
        Task.shutdown(task)

        finish_session(state, %{
          "summary" => "Agent step timed out after #{@per_step_timeout}ms"
        })

      {:ok, {:continue, state}} ->
        loop(state)

      {:ok, {:done, _state}} ->
        :ok

      {:ok, {:error, state, reason}} ->
        Logger.warning("Agent.Engine: step failed: #{inspect(reason)}")
        finish_session(state, %{"summary" => "Agent step failed: #{inspect(reason)}"})

      {:ok, result} ->
        Logger.warning("Agent.Engine: unexpected step result: #{inspect(result)}")
        finish_session(state, %{"summary" => "Agent step returned unexpected result"})

      {:exit, reason} ->
        Logger.warning("Agent.Engine: step crashed: #{inspect(reason)}")
        finish_session(state, %{"summary" => "Agent step crashed: #{inspect(reason)}"})
    end
  end

  defp single_turn(state) do
    case call_llm(state) do
      {:ok, %{reasoning: reasoning, tool: tool, args: args, assistant_message: assistant_message}} ->
        state = %{state | step: state.step + 1}
        step = log_step!(state, tool, args, reasoning)
        broadcast(state, {:step_started, step})

        {result, state} = state.module.execute_tool(tool, args, state)
        update_step!(step, result, state.module)
        broadcast(state, {:step_completed, step, summarize_result(result, state.module)})

        if tool == "done" do
          finish_session(state, args)
          {:done, state}
        else
          state = add_to_messages(state, assistant_message, tool, result)
          {:continue, state}
        end

      {:error, reason} ->
        {:error, state, reason}
    end
  rescue
    reason ->
      {:error, state, reason}
  end

  # ── LLM ──

  defp call_llm(state) do
    payload = %{
      "model" => Inference.chat_model(),
      "messages" => state.messages,
      "tools" => state.module.tools(),
      "tool_choice" => "auto",
      "temperature" => 0.4,
      "max_tokens" => @max_completion_tokens
    }

    case Inference.chat(payload) do
      {:ok, message} -> extract_tool_call(message)
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_tool_call(message) do
    case List.first(Map.get(message, "tool_calls", [])) do
      %{"function" => %{"name" => name, "arguments" => args}} when is_binary(args) ->
        case Jason.decode(args) do
          {:ok, decoded} ->
            {:ok,
             %{
               reasoning: reasoning_from_message(message),
               tool: name,
               args: decoded,
               assistant_message: message
             }}

          _ ->
            {:error, :invalid_tool_args}
        end

      %{"function" => %{"name" => name, "arguments" => args}} when is_map(args) ->
        {:ok,
         %{
           reasoning: reasoning_from_message(message),
           tool: name,
           args: args,
           assistant_message: message
         }}

      _ ->
        content = Map.get(message, "content", "")
        parse_response(content)
    end
  end

  defp reasoning_from_message(message) do
    Map.get(message, "content", "") |> String.trim()
  end

  defp parse_response(text) do
    text = String.trim(text)

    case extract_json(text) do
      nil ->
        {:error, :no_json}

      json_str ->
        case Jason.decode(json_str) do
          {:ok, decoded} when is_map(decoded) ->
            {:ok,
             %{
               reasoning: Map.get(decoded, "reasoning", ""),
               tool: Map.get(decoded, "tool", ""),
               args: Map.get(decoded, "args", %{}),
               assistant_message: %{"content" => text}
             }}

          _ ->
            {:error, :invalid_json}
        end
    end
  end

  defp extract_json(text) do
    cond do
      String.contains?(text, "```json") ->
        case Regex.run(~r/```json\s*(.*?)\s*```/s, text) do
          [_, json] -> json
          _ -> nil
        end

      Regex.match?(~r/^\s*\{.*\}\s*$/s, text) ->
        text

      true ->
        case Regex.run(~r/\{.*\}/s, text) do
          [json] -> json
          _ -> nil
        end
    end
  end

  # ── DB logging ──

  defp log_step!(state, tool, args, reasoning) do
    {:ok, step} =
      %Step{}
      |> Step.changeset(%{
        session_id: state.session.id,
        step_number: state.step,
        tool_name: tool,
        tool_args: args,
        reasoning: reasoning
      })
      |> Repo.insert()

    Repo.update_all(
      from(s in Session, where: s.id == ^state.session.id),
      set: [steps_count: state.step]
    )

    step
  end

  defp update_step!(step, result, module) do
    step
    |> Step.changeset(%{tool_result: summarize_result(result, module)})
    |> Repo.update!()
  end

  @doc """
  Summarize a tool result for DB storage and future messages.

  The default implementation works for lists, maps, `:done`, and errors.
  Agent modules can export `summarize_result/1` to override.
  """
  @spec summarize_result(term(), module() | nil) :: map()
  def summarize_result(result, module \\ nil)

  def summarize_result(result, module) when is_atom(module) and not is_nil(module) do
    if function_exported?(module, :summarize_result, 1) do
      module.summarize_result(result)
    else
      default_summarize_result(result)
    end
  end

  def summarize_result(result, _), do: default_summarize_result(result)

  defp default_summarize_result({:ok, data}) when is_list(data),
    do: %{status: "ok", count: length(data), data: data}

  defp default_summarize_result({:ok, data}) when is_map(data),
    do: %{status: "ok", data: data}

  defp default_summarize_result({:ok, :done}), do: %{status: "done"}
  defp default_summarize_result({:error, reason}), do: %{status: "error", error: inspect(reason)}

  # ── Session lifecycle ──

  defp finish_session(state, args) do
    summary = args["summary"] || "Agent completed"

    Repo.get!(Session, state.session.id)
    |> Session.changeset(%{
      status: "done",
      summary: summary,
      pages_created: state.pages_created,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update!()

    broadcast(state, {:session_done, summary, state.pages_created})
  end

  # ── PubSub ──

  defp broadcast(state, message) do
    Phoenix.PubSub.broadcast(Dran.PubSub, "agents:#{state.session.id}", message)
    Phoenix.PubSub.broadcast(Dran.PubSub, "agents:all", {:agent, state.session.id, message})
  end

  # ── Helpers ──

  defp add_to_messages(state, assistant_message, _tool, result) do
    tool_result_str = format_tool_result(result, state.module)
    tool_call_id = get_tool_call_id(assistant_message)

    assistant_entry =
      Map.merge(assistant_message, %{
        "role" => "assistant",
        "content" => Map.get(assistant_message, "content", "")
      })

    tool_entry = %{
      "role" => "tool",
      "tool_call_id" => tool_call_id,
      "content" => tool_result_str
    }

    %{state | messages: state.messages ++ [assistant_entry, tool_entry]}
  end

  defp get_tool_call_id(%{"tool_calls" => [%{"id" => id} | _]}), do: id
  defp get_tool_call_id(_), do: "call_fallback"

  defp format_tool_result(result, module) do
    summary = summarize_result(result, module)

    case summary do
      %{data: data} when is_list(data) ->
        data
        |> Enum.take(5)
        |> Enum.map_join("\n", fn item ->
          text = "- #{item[:title] || item[:url] || item[:slug] || inspect(item)}"
          String.slice(text, 0, 200)
        end)

      %{data: data} when is_map(data) ->
        Jason.encode!(data) |> String.slice(0, @max_tool_result_chars)

      %{status: status} ->
        to_string(status)
    end
  end
end
