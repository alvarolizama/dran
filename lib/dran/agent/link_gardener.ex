defmodule Dran.Agent.LinkGardener do
  @moduledoc """
  Link Gardener agent: reads orphaned or under-linked pages, searches for
  candidates, and proposes typed relations between pages with a one-line
  justification.

  Enforces a hard limit of `@max_proposals` (10) relations per session and
  forbids the `semantic` relation type — that type is reserved for the
  automatic embedding-based augmenter.

  Allowed relation types:

    * `part_of`     — source is part of target
    * `supersedes`  — source replaces/obsoletes target
    * `contradicts` — source contradicts target
    * `related`     — generic connection

  Each proposed relation is created with a `meta` map carrying the
  justification and the `proposed_by` marker so downstream consumers can
  distinguish agent-suggested relations from manual or auto ones.
  """

  @behaviour Dran.Agent.Engine.Behaviour
  use Dran.Agent.Schedulable, input: "scheduled weekly run"

  alias Dran.Brain

  @agent_type "link_gardener"
  @max_proposals 10

  @allowed_relation_types ~w(part_of supersedes contradicts related)

  defmodule State do
    @moduledoc false
    defstruct session: nil,
              module: nil,
              messages: [],
              step: 0,
              pages_created: 0,
              opts: [],
              proposals_made: 0
  end

  @doc """
  Start a link gardener session for a topic/context.
  """
  @spec run(String.t(), Ecto.UUID.t(), keyword()) :: {:ok, Dran.Agent.Session.t()}
  def run(topic, workspace_id, opts \\ []) do
    Dran.Agent.Engine.run(__MODULE__, topic, workspace_id, opts)
  end

  @impl true
  def agent_type, do: @agent_type

  @doc "Maximum number of relations a single session may propose."
  def max_proposals, do: @max_proposals

  @doc "List of relation types this agent is allowed to propose."
  def allowed_relation_types, do: @allowed_relation_types

  @impl true
  def tools do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "list_orphans",
          "description" =>
            "List pages in the brain that have no inbound relations (orphans). " <>
              "Use this to find pages that need linking.",
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
          "name" => "get_page",
          "description" => "Read the full content of a page by its slug.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "slug" => %{
                "type" => "string",
                "description" => "Slug of the page to read"
              }
            },
            "required" => ["slug"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "search",
          "description" =>
            "Search existing pages in the brain by query. " <>
              "Returns matching pages with slug, title, and a snippet.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "query" => %{
                "type" => "string",
                "description" => "Search query"
              }
            },
            "required" => ["query"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "transitive_candidates",
          "description" =>
            "List candidate `part_of` relations inferred transitively: " <>
              "pairs (A, C) where A is already part_of B and B is part_of C, " <>
              "but the direct A part_of C relation does NOT yet exist. " <>
              "Each candidate includes the intermediate page `via_slug` as " <>
              "evidence. Use this as a starting point — ALWAYS verify with " <>
              "`get_page` before proposing the relation, and cite the " <>
              "intermediate page in the justification (e.g. \"A ya es parte " <>
              "de B, y B es parte de C\").",
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
          "name" => "propose_relation",
          "description" =>
            "Propose a typed relation between two pages with a one-line justification. " <>
              "Allowed relation_type: part_of, supersedes, contradicts, related. " <>
              "NEVER use \"semantic\" — it is reserved for automatic embeddings. " <>
              "Maximum #{max_proposals()} proposals per session.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "source_slug" => %{
                "type" => "string",
                "description" => "Slug of the source page"
              },
              "target_slug" => %{
                "type" => "string",
                "description" => "Slug of the target page"
              },
              "relation_type" => %{
                "type" => "string",
                "enum" => @allowed_relation_types,
                "description" =>
                  "One of: part_of, supersedes, contradicts, related. " <>
                    "Never \"semantic\"."
              },
              "justification" => %{
                "type" => "string",
                "description" => "One-line justification for the relation"
              }
            },
            "required" => ["source_slug", "target_slug", "relation_type", "justification"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "done",
          "description" => "Finish the link gardening session with a summary.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "summary" => %{
                "type" => "string",
                "description" => "Short summary of relations proposed"
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
    You are the Link Gardener for Dran, a knowledge brain. Your job is to tend
    the graph of pages by proposing typed relations between pages that are
    orphaned or under-linked.

    Workflow:
    0. (Optional but recommended) Call `transitive_candidates` first to
       fetch structurally-evidenced `part_of` proposals: pairs (A, C)
       where A is already part_of B and B is part_of C, but the direct
       A part_of C relation does not yet exist. Each candidate includes
       the intermediate page `via_slug` as evidence.
    1. Call `list_orphans` to find pages with no inbound relations.
    2. For each orphan (or page with few relations), use `get_page` to read
       its content, then `search` for candidate pages it might relate to.
    3. Read the candidate pages with `get_page` to confirm the relation makes
       sense. ALWAYS verify a candidate with `get_page` before proposing it
       — never propose a relation based solely on the candidate list.
    4. Call `propose_relation` with:
       - source_slug, target_slug
       - relation_type: one of part_of, supersedes, contradicts, related
       - justification: a single concise line explaining WHY the relation holds.
         For transitive candidates, cite the intermediate page as evidence,
         e.g. "A ya es parte de B, y B es parte de C" (where B is the via_slug).
    5. Repeat for other orphans. Call `done` when finished.

    RULES — critical:
    - NEVER propose a relation_type of "semantic". That type is reserved for
      the automatic embedding-based augmenter. The allowed types are exactly:
      part_of, supersedes, contradicts, related.
    - You may propose at most #{max_proposals()} relations per session. After
      that, further proposals are rejected.
    - Only propose a relation when the page contents genuinely support it.
      Do not invent connections. The justification must reference the actual
      content.
    - Prefer high-signal relations (supersedes, contradicts, part_of) over the
      generic "related" when the content warrants it.

    Be efficient: read what you need, propose, and finish. Do not loop
    indefinitely over orphans.
    """
  end

  def build_messages(input, session, _opts \\ []) do
    [
      %{"role" => "system", "content" => system_prompt()},
      %{"role" => "user", "content" => "Tend links for: #{input}\nSession: #{session.id}"}
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
      proposals_made: 0
    }
  end

  # ── Tool execution ────────────────────────────────────────────────────────

  @impl true
  def execute_tool("transitive_candidates", _args, %State{} = state) do
    candidates = Brain.transitive_part_of_candidates(state.session.workspace_id)
    {{:ok, candidates}, state}
  end

  @impl true
  def execute_tool("list_orphans", _args, %State{} = state) do
    orphans = Brain.orphan_pages(state.session.workspace_id)
    {{:ok, orphans}, state}
  end

  def execute_tool("get_page", args, %State{} = state) do
    slug = String.trim(args["slug"] || "")

    if slug == "" do
      {{:error, "empty slug"}, state}
    else
      case Brain.get_page_by_slug(slug, state.session.workspace_id) do
        nil ->
          {{:error, "page '#{slug}' not found"}, state}

        page ->
          {{:ok,
            %{
              slug: page.slug,
              title: page.title,
              body: page.body,
              page_type: page.page_type,
              tags: page.tags
            }}, state}
      end
    end
  end

  def execute_tool("search", args, %State{} = state) do
    result =
      Brain.search(args["query"] || "", workspace_id: state.session.workspace_id, limit: 10)

    {result, state}
  end

  def execute_tool("propose_relation", args, %State{} = state) do
    source_slug = String.trim(args["source_slug"] || "")
    target_slug = String.trim(args["target_slug"] || "")
    relation_type = args["relation_type"] || ""
    justification = String.trim(args["justification"] || "")

    cond do
      relation_type == "semantic" ->
        {{:error,
          "relation_type \"semantic\" is not allowed. " <>
            "Use one of: part_of, supersedes, contradicts, related."}, state}

      relation_type not in @allowed_relation_types ->
        {{:error,
          "invalid relation_type '#{relation_type}'. " <>
            "Allowed: part_of, supersedes, contradicts, related."}, state}

      source_slug == "" or target_slug == "" ->
        {{:error, "source_slug and target_slug are required"}, state}

      justification == "" ->
        {{:error, "justification is required"}, state}

      state.proposals_made >= @max_proposals ->
        {{:error, "proposal limit reached"}, state}

      true ->
        workspace_id = state.session.workspace_id

        source = Brain.get_page_by_slug(source_slug, workspace_id)
        target = Brain.get_page_by_slug(target_slug, workspace_id)

        cond do
          is_nil(source) ->
            {{:error, "source page '#{source_slug}' not found"}, state}

          is_nil(target) ->
            {{:error, "target page '#{target_slug}' not found"}, state}

          source.id == target.id ->
            {{:error, "source and target must be different pages"}, state}

          true ->
            meta = %{
              "justification" => justification,
              "proposed_by" => "link-gardener"
            }

            case Brain.create_relation(%{
                   source_id: source.id,
                   target_id: target.id,
                   relation_type: relation_type,
                   meta: meta
                 }) do
              {:ok, relation} ->
                {{:ok,
                  %{
                    id: relation.id,
                    source_slug: source.slug,
                    target_slug: target.slug,
                    relation_type: relation_type,
                    justification: justification
                  }}, %{state | proposals_made: state.proposals_made + 1}}

              {:error, cs} ->
                {{:error, format_changeset_errors(cs)}, state}
            end
        end
    end
  end

  def execute_tool("done", _args, %State{} = state), do: {{:ok, :done}, state}

  def execute_tool(_tool, _args, %State{} = state), do: {{:error, :unknown_tool}, state}

  # ── Behaviour callbacks (optional) ───────────────────────────────────────

  @impl true
  def summarize_result({:ok, :done}), do: %{status: "done"}

  def summarize_result({:ok, %{id: id, relation_type: rt}}) do
    %{status: "ok", relation_id: id, relation_type: rt}
  end

  def summarize_result({:ok, pages}) when is_list(pages) do
    %{status: "ok", count: length(pages), data: pages}
  end

  # get_page result — preserve body so the LLM can read page content
  def summarize_result({:ok, %{slug: _slug, title: _title, body: _body} = page}) do
    %{status: "ok", data: Map.take(page, [:slug, :title, :body, :page_type, :tags])}
  end

  def summarize_result({:ok, %{slug: slug, title: title}}) do
    %{status: "ok", slug: slug, title: title}
  end

  def summarize_result({:ok, %{slug: slug}}) do
    %{status: "ok", slug: slug}
  end

  def summarize_result({:error, reason}) when is_binary(reason) do
    %{status: "error", error: reason}
  end

  def summarize_result({:error, reason}), do: %{status: "error", error: inspect(reason)}

  @impl true
  def gathered_summary(%State{proposals_made: n}) do
    "Link Gardener has proposed #{n} relation(s) so far. " <>
      "Maximum is #{@max_proposals}. Finish with `done` when you have proposed enough."
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

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
