defmodule Mix.Tasks.Dran.Agent do
  @moduledoc """
  CLI entry point for running Dran agents.

  Usage:

      mix dran.agent --type research --context personal --input "Yeshe Walmo"
      mix dran.agent --type ingest --context personal --input "https://example.com/article"

  Options:
    * `--type` — one of `research`, `ingest` (required)
    * `--context` — context slug (required)
    * `--input` — agent input, e.g. topic, URL, or query (required)
    * `--sync` — block until the session completes and print summary
  """

  use Mix.Task

  alias Dran.Agent
  alias Dran.Brain
  alias Dran.Repo

  @shortdoc "Run a Dran agent from the command line"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _args, _invalid} =
      OptionParser.parse(args,
        strict: [type: :string, context: :string, input: :string, sync: :boolean],
        aliases: [t: :type, c: :context, i: :input]
      )

    type = opts[:type]
    context_slug = opts[:context]
    input = opts[:input]
    sync? = opts[:sync] || false

    unless type && context_slug && input do
      raise "--type, --context and --input are required"
    end

    context = Brain.get_context_by_slug(context_slug)

    unless context do
      raise "context '#{context_slug}' not found"
    end

    {:ok, session} = start_agent(type, input, context.id)

    IO.puts("Started #{type} agent session: #{session.id}")

    if sync? do
      IO.puts("Waiting for completion...")
      wait_for_session(session.id)
    end
  end

  defp start_agent("research", input, context_id), do: Agent.Research.run(input, context_id)
  defp start_agent("ingest", input, context_id), do: Agent.Ingest.run(input, context_id)

  defp wait_for_session(session_id) do
    :timer.sleep(500)

    case Repo.get(Agent.Session, session_id) do
      nil ->
        IO.puts("Session not found")

      %{status: "done"} = session ->
        IO.puts("Done: #{session.summary}")
        IO.puts("Pages created: #{session.pages_created}")

      %{status: status} ->
        IO.puts("Status: #{status}")
        wait_for_session(session_id)
    end
  end
end
