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

  @doc """
  Optionally builds the initial agent state.

  Default is a plain map `%{session: session, module: module, messages: ...,
  step: 0, pages_created: 0, opts: opts}`. Agents that need extra tracking
  fields (e.g. scraped URLs) can return a custom struct.
  """
  @callback init_state(Dran.Agent.Session.t(), module(), keyword()) :: term()

  @doc "Executes a tool call. Must return `{result, new_state}`."
  @callback execute_tool(String.t(), map(), term()) :: {term(), term()}

  @doc "Optionally customizes how a tool result is summarized before DB/logging."
  @callback summarize_result(term()) :: map()

  @doc """
  Optionally returns a human-readable summary of what the agent has gathered
  so far. Used by the engine when nudging the LLM toward synthesis after
  repeated tool errors.
  """
  @callback gathered_summary(term()) :: String.t()

  @optional_callbacks [summarize_result: 1, init_state: 3, gathered_summary: 1]
end
