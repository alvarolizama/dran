defmodule Dran.Agent.Engine.Behaviour do
  @moduledoc """
  Behaviour contract for agent modules that run on `Dran.Agent.Engine`.
  """

  @doc "Returns the agent type string (e.g. \"research\")."
  @callback agent_type() :: String.t()

  @doc "Returns a list of OpenAI-compatible function tool schemas."
  @callback tools() :: list(map())

  @doc "Returns the system prompt for the LLM."
  @callback system_prompt() :: String.t()

  @doc "Builds the initial messages list from the user input and session."
  @callback build_messages(String.t(), Dran.Agent.Session.t()) :: list(map())

  @doc "Executes a tool call. Must return `{result, new_state}`."
  @callback execute_tool(String.t(), map(), term()) :: {term(), term()}

  @doc "Optionally customizes how a tool result is summarized before DB/logging."
  @callback summarize_result(term()) :: map()

  @optional_callbacks [summarize_result: 1]
end
