defmodule Dran.Agent.Curator do
  @moduledoc """
  Curator agent: the "conserje" (janitor) of the brain.

  Reviews pairs of pages with very similar embeddings, decides which are
  genuine duplicates vs. distinct content, flags contested pages, and
  writes a report note explaining its decisions.

  Enforces a hard limit of `@max_flags` (20) contested flags per session.

  Tools:
    * `find_duplicates` — direct DB query (no LLM), returns page pairs with
      embedding distance < 0.05.
    * `flag_contested` — sets `kb_contested = true` on pages by slug.
    * `lint_report` — delegates to `Brain.lint/1`.
    * `create_note` — creates a `note` page with the curator's report.
    * `done` — finishes the session.
  """

  @behaviour Dran.Agent.Engine.Behaviour
  use Dran.Agent.Schedulable, input: "scheduled run"

  import Ecto.Query

  alias Dran.{Brain, Repo}
  alias Dran.Brain.Page

  @agent_type "curator"
  @max_flags 20
  @duplicate_threshold 0.05

  defmodule State do
    @moduledoc false
    defstruct session: nil,
              module: nil,
              messages: [],
              step: 0,
              pages_created: 0,
              opts: [],
              duplicate_pairs: [],
              flags_made: 0
  end

  @doc """
  Start a curator session.
  """
  @spec run(String.t(), Ecto.UUID.t(), keyword()) :: {:ok, Dran.Agent.Session.t()}
  def run(input, context_id, opts \\ []) do
    Dran.Agent.Engine.run(__MODULE__, input, context_id, opts)
  end

  @impl true
  def agent_type, do: @agent_type

  @doc "Maximum number of contested flags per session."
  def max_flags, do: @max_flags

  @doc "Embedding distance threshold below which two pages are considered duplicates."
  def duplicate_threshold, do: @duplicate_threshold

  @impl true
  def tools do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "find_duplicates",
          "description" =>
            "Find pairs of pages in the brain with very similar embeddings (cosine distance < #{duplicate_threshold()}). " <>
              "Returns up to 20 pairs. Use this to identify potential duplicate content.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{},
            "required" => []
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "flag_contested",
          "description" =>
            "Flag pages as contested (kb_contested = true) by their slugs. " <>
              "Use this for pages that are duplicates or whose content is disputed. " <>
              "Maximum #{max_flags()} flags per session.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "slugs" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "Slugs of the pages to flag as contested"
              }
            },
            "required" => ["slugs"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "lint_report",
          "description" =>
            "Generate a lint report for the brain: orphan pages, stale pages, and contested pages.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{},
            "required" => []
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "create_note",
          "description" =>
            "Create a note page with the curator report. The title will be 'Curator report <date>'.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "body" => %{
                "type" => "string",
                "description" => "Markdown body of the report explaining decisions"
              }
            },
            "required" => ["body"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "done",
          "description" => "Finish the curator session with a summary.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "summary" => %{
                "type" => "string",
                "description" => "Short summary of what was reviewed and decided"
              }
            },
            "required" => ["summary"]
          }
        }
      }
    ]
  end

  @impl true
  def system_prompt(_opts \\ []) do
    """
    You are the Curator of Dran, a knowledge brain. You are the "conserje"
    (janitor) of the brain — your job is to keep it clean and well-organized.

    Workflow:
    1. Call `find_duplicates` to get pairs of pages with very similar embeddings.
       Each pair includes a `same_community` boolean: when true, the graph
       community-detection algorithm also placed both pages in the same
       community (dense shared neighborhood). This is additional evidence
       that the pages are about the same topic — weigh it alongside the
       embedding distance, but do not treat it as conclusive on its own.
       When `same_community` is false, the pages are embedding-close but
       structurally in different communities (weaker duplicate signal).
    2. For each pair, decide whether they are:
       - True duplicates: same content, should be merged or one deleted.
         Strongest when `same_community` is true AND distance is very small.
       - Contested: different takes on the same topic, or conflicting information.
       - Distinct: similar embeddings but genuinely different content.
    3. Call `flag_contested` with the slugs of pages that are duplicates or
       whose content is disputed. You may flag at most #{max_flags()} pages
       per session.
    4. Optionally call `lint_report` to get an overview of orphan, stale, and
       contested pages.
    5. Call `create_note` with a markdown report explaining your decisions:
       which pairs you reviewed, which you flagged as contested and why,
       and which you left alone.
    6. Call `done` with a short summary.

    RULES:
    - Only flag pages that genuinely need attention. Do not flag everything.
    - The report note should be concise but informative.
    - Be efficient: review the pairs, make decisions, write the report, finish.
    """
  end

  def build_messages(input, session, _opts \\ []) do
    [
      %{"role" => "system", "content" => system_prompt()},
      %{"role" => "user", "content" => "Curator task: #{input}\nSession: #{session.id}"}
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
      duplicate_pairs: [],
      flags_made: 0
    }
  end

  # ── Tool execution ────────────────────────────────────────────────────────

  @impl true
  def execute_tool("find_duplicates", _args, %State{} = state) do
    context_id = state.session.context_id

    pairs =
      Repo.all(
        from p1 in Page,
          join: p2 in Page,
          on: p1.context_id == p2.context_id and p1.id < p2.id,
          where:
            p1.context_id == ^context_id and
              not is_nil(p1.embedding) and not is_nil(p2.embedding),
          where: fragment("? <=> ?", p1.embedding, p2.embedding) < ^@duplicate_threshold,
          order_by: fragment("? <=> ?", p1.embedding, p2.embedding),
          limit: 20,
          select: %{
            a: %{
              id: p1.id,
              slug: p1.slug,
              title: p1.title,
              meta: p1.meta
            },
            b: %{
              id: p2.id,
              slug: p2.slug,
              title: p2.title,
              meta: p2.meta
            },
            distance: fragment("? <=> ?", p1.embedding, p2.embedding)
          }
      )
      |> Enum.map(fn pair ->
        cid1 = get_in(pair.a, [:meta, "community_id"])
        cid2 = get_in(pair.b, [:meta, "community_id"])

        # same_community is additional duplicate evidence: two pages that
        # the graph algorithm placed in the same community are structurally
        # close (dense shared neighborhood) on top of being embedding-close.
        # nil on either side means communities haven't been refreshed yet.
        same_community = cid1 != nil and cid1 == cid2

        pair
        |> put_in([:a], Map.delete(pair.a, :meta))
        |> put_in([:b], Map.delete(pair.b, :meta))
        |> Map.put(:same_community, same_community)
      end)

    {{:ok, pairs}, %{state | duplicate_pairs: pairs}}
  end

  def execute_tool("flag_contested", args, %State{} = state) do
    slugs = args["slugs"] || []

    cond do
      slugs == [] ->
        {{:error, "no slugs provided"}, state}

      state.flags_made >= @max_flags ->
        {{:error, "flag limit reached (#{@max_flags} per session)"}, state}

      true ->
        context_id = state.session.context_id

        {flagged, errors} =
          Enum.reduce(slugs, {[], []}, fn slug, {flagged_acc, err_acc} ->
            case Brain.get_page_by_slug(slug, context_id) do
              nil ->
                {flagged_acc, err_acc ++ ["page '#{slug}' not found"]}

              page ->
                case page
                     |> Ecto.Changeset.change(kb_contested: true)
                     |> Repo.update() do
                  {:ok, _} ->
                    {[slug | flagged_acc], err_acc}

                  {:error, _cs} ->
                    {flagged_acc, err_acc ++ ["failed to flag '#{slug}'"]}
                end
            end
          end)

        flagged = Enum.reverse(flagged)
        new_flags = state.flags_made + length(flagged)

        result = %{
          flagged: flagged,
          errors: errors,
          total_flags_this_session: new_flags
        }

        {{:ok, result}, %{state | flags_made: new_flags}}
    end
  end

  def execute_tool("lint_report", _args, %State{} = state) do
    report = Brain.lint(state.session.context_id)
    {{:ok, report}, state}
  end

  def execute_tool("create_note", args, %State{} = state) do
    body = args["body"] || ""

    if String.trim(body) == "" do
      {{:error, "body is required"}, state}
    else
      date = Date.utc_today() |> Date.to_iso8601()
      title = "Curator report #{date}"

      page_attrs = %{
        context_id: state.session.context_id,
        title: title,
        body: body,
        page_type: "note",
        created_by: "curator",
        owner: "curator",
        meta: %{"agent_session_id" => state.session.id}
      }

      case Brain.create_page(page_attrs) do
        {:ok, page} ->
          Phoenix.PubSub.broadcast(
            Dran.PubSub,
            "agents:#{state.session.id}",
            {:page_created, page}
          )

          {{:ok, %{slug: page.slug, id: page.id, title: page.title}},
           %{state | pages_created: state.pages_created + 1}}

        {:error, cs} ->
          {{:error, format_changeset_errors(cs)}, state}
      end
    end
  end

  def execute_tool("done", _args, %State{} = state), do: {{:ok, :done}, state}

  def execute_tool(_tool, _args, %State{} = state), do: {{:error, :unknown_tool}, state}

  # ── Behaviour callbacks (optional) ─────────────────────────────────────────

  @impl true
  def summarize_result({:ok, :done}), do: %{status: "done"}

  def summarize_result({:ok, pairs}) when is_list(pairs) do
    %{status: "ok", count: length(pairs), data: pairs}
  end

  def summarize_result({:ok, %{slug: slug, title: title}}) do
    %{status: "ok", slug: slug, title: title}
  end

  def summarize_result({:ok, %{flagged: flagged}}) do
    %{status: "ok", flagged: flagged}
  end

  def summarize_result({:ok, report}) when is_map(report) do
    %{status: "ok", data: report}
  end

  def summarize_result({:error, reason}) when is_binary(reason) do
    %{status: "error", error: reason}
  end

  def summarize_result({:error, reason}), do: %{status: "error", error: inspect(reason)}

  @impl true
  def gathered_summary(%State{flags_made: flags, duplicate_pairs: pairs}) do
    "Curator has found #{length(pairs)} duplicate pair(s) and flagged #{flags} page(s). " <>
      "Maximum flags is #{@max_flags}. Write your report with `create_note` and call `done`."
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
