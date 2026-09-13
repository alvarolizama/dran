defmodule DranWeb.API.MemoryController do
  @moduledoc """
  REST API for the shared multi-agent memory store.

  Attribution: `created_by` is derived server-side from the authenticated
  identity (API key name / user email) via `Dran.Auth.resolve_created_by/1` —
  it is never client-settable, so every fact is attributable to the agent
  that stored it.

  The ingest endpoint never persists the transcript: it extracts atomic
  facts server-side with `Dran.Inference`, stores them through the normal
  dedupe path, and discards the raw conversation.
  """

  use DranWeb, :controller

  alias Dran.Auth
  alias Dran.Inference
  alias Dran.Knowledge
  alias Dran.Memory

  @max_transcript_chars 12_000
  @max_facts_per_ingest 5
  # Auto-extracted facts start below the manual 0.5 baseline (probation):
  # they surface in search with less weight until feedback promotes them.
  @auto_extracted_trust 0.35
  # Self-reported confidence floor from the extraction model.
  @min_extraction_confidence 0.7

  @doc """
  POST /api/memory — store a fact (dedupe per workspace: exact hash →
  semantic duplicate → semantic near-duplicate grey zone → create).

  Pass `force=true` to skip the semantic grey zone when the caller has
  examined the near-duplicate and confirmed the fact is genuinely new.
  """
  def create(conn, params) do
    params = resolve_workspace_id(conn, params)
    user = conn.assigns[:user]

    attrs = %{
      "workspace_id" => params["workspace_id"],
      "content" => params["content"],
      "source_session" => params["source_session"],
      "created_by" => Auth.resolve_created_by(user)
    }

    opts = if params["force"] in [true, "true", "1"], do: [force: true], else: []

    case Memory.add(attrs, opts) do
      {:ok, memory, :created} ->
        conn
        |> put_status(:created)
        |> json(%{data: memory, duplicate: false})

      {:ok, memory, :duplicate} ->
        json(conn, %{data: memory, duplicate: true})

      {:ok, existing, :near_duplicate} ->
        # Grey zone (cosine 0.88–0.95): not stored. Return both texts so the
        # caller (agent) can decide — refine via PATCH, or re-add with force.
        conn
        |> put_status(:conflict)
        |> json(%{
          near_duplicate: true,
          data: existing,
          submitted: params["content"]
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{errors: %{detail: to_string(reason)}})
    end
  end

  @doc """
  PATCH /api/memory/:id — rewrite a fact in place (Holographic `update`
  semantics). Trust, feedback and retrieval counters survive the rewrite;
  content is re-embedded. Same-content PATCH is a no-op returning the row.
  """
  def update(conn, %{"id" => id} = params) do
    params = resolve_workspace_id(conn, params)

    with :ok <- require_content(params),
         memory when not is_nil(memory) <-
           Memory.get_scoped_memory(id, params["workspace_id"]) do
      case Memory.update_memory(memory, params["content"]) do
        {:ok, updated} ->
          json(conn, %{data: render_memory(%{memory: updated, score: nil})})

        {:error, :superseded} ->
          conn
          |> put_status(:conflict)
          |> json(%{errors: %{detail: "memory is superseded"}})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_errors(changeset)})

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{errors: %{detail: to_string(reason)}})
      end
    else
      {:error, :content_required} ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: %{detail: "content is required"}})

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "memory not found"}})
    end
  end

  defp require_content(params) do
    if blank?(params["content"]),
      do: {:error, :content_required},
      else: :ok
  end

  @doc "GET /api/memory/search?q=&workspace=&limit= — trust-weighted hybrid search."
  def search(conn, params) do
    params = resolve_workspace_id(conn, params)

    cond do
      blank?(params["q"]) ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: %{detail: "q query param is required"}})

      blank?(params["workspace_id"]) ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: %{detail: "workspace query param is required"}})

      true ->
        limit = parse_limit(params["limit"])

        results =
          Memory.search(params["workspace_id"], params["q"], limit: limit)

        json(conn, %{data: Enum.map(results, &render_memory/1)})
    end
  end

  @doc "GET /api/memory — list memories of a workspace, newest first."
  def index(conn, params) do
    params = resolve_workspace_id(conn, params)

    memories =
      Memory.list_memories(params["workspace_id"],
        status: params["status"],
        limit: parse_limit(params["limit"]),
        offset: parse_int(params["offset"])
      )

    json(conn, %{data: memories})
  end

  @doc "POST /api/memory/feedback — rate a fact as helpful/unhelpful."
  def feedback(conn, %{"id" => id, "helpful" => helpful} = params) do
    params = resolve_workspace_id(conn, params)

    helpful? =
      case helpful do
        true -> true
        "true" -> true
        false -> false
        "false" -> false
        _ -> nil
      end

    cond do
      is_nil(helpful?) ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: %{detail: "helpful must be a boolean"}})

      not scoped_memory_exists?(id, params["workspace_id"]) ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "memory not found"}})

      true ->
        case Memory.record_feedback(id, helpful?) do
          {:ok, memory} ->
            json(conn, %{
              data: %{
                id: memory.id,
                trust_score: memory.trust_score,
                helpful_count: memory.helpful_count
              }
            })

          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{errors: %{detail: "memory not found"}})

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{errors: %{detail: to_string(reason)}})
        end
    end
  end

  def feedback(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "id and helpful are required"}})
  end

  @doc """
  POST /api/memory/ingest — extract facts from a session transcript
  server-side and store them. The transcript is never persisted.
  """
  def ingest(conn, params) do
    params = resolve_workspace_id(conn, params)
    user = conn.assigns[:user]

    cond do
      blank?(params["workspace_id"]) ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: %{detail: "workspace query param is required"}})

      blank?(transcript_text(params["transcript"])) ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: %{detail: "transcript is required"}})

      not Inference.enabled?() ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{errors: %{detail: "inference is not configured"}})

      true ->
        transcript = transcript_text(params["transcript"])

        # Existing facts give the extractor negative context: slots are not
        # wasted re-extracting what the workspace already knows. The top-10
        # is inflated with their semantic memory↔memory neighbours — the
        # extractor must also skip related variants, not just exact dupes.
        known =
          case Memory.search(params["workspace_id"], transcript,
                 limit: 10,
                 bump_retrieval: false
               ) do
            [] ->
              []

            facts ->
              base_ids = Enum.map(facts, & &1.memory.id)
              base_contents = Enum.map(facts, & &1.memory.content)

              neighbor_contents =
                params["workspace_id"]
                |> Memory.related_snapshots(base_ids)
                |> Enum.flat_map(fn {_id, neighbors} -> neighbors end)
                |> Enum.map(& &1.content)
                |> Enum.uniq()

              Enum.uniq(base_contents ++ neighbor_contents)
          end

        case extract_facts(transcript, known, summary_language(params["workspace_id"])) do
          {:error, :extraction_failed} ->
            json(conn, %{facts: [], created: 0, duplicates: 0, error: "extraction_failed"})

          {:ok, facts} ->
            facts
            |> Enum.take(@max_facts_per_ingest)
            |> Enum.reduce(%{created: 0, duplicates: 0, facts: []}, fn content, acc ->
              attrs = %{
                "workspace_id" => params["workspace_id"],
                "content" => content,
                "source_session" => params["source_session"],
                "created_by" => Auth.resolve_created_by(user),
                # Auto-extracted facts start on probation: they weigh less in
                # search until feedback promotes them. Manual adds stay at 0.5.
                "trust_score" => @auto_extracted_trust
              }

              case Memory.add(attrs) do
                {:ok, memory, :created} ->
                  %{acc | created: acc.created + 1, facts: [memory.content | acc.facts]}

                {:ok, _existing, :duplicate} ->
                  %{acc | duplicates: acc.duplicates + 1}

                # Grey-zone matches on auto-extracted facts count as
                # duplicates: no LLM round-trip, no forced row — the
                # extractor's rewording is not trusted enough to overwrite
                # a human/agent-curated fact.
                {:ok, _existing, :near_duplicate} ->
                  %{acc | duplicates: acc.duplicates + 1}

                {:error, _} ->
                  acc
              end
            end)
            |> then(fn result -> json(conn, result) end)
        end
    end
  end

  @doc """
  DELETE /api/memory/:id?workspace= — soft-remove a fact (superseded).

  Pass `purge=true` to hard-delete the row permanently instead.
  """
  def delete(conn, %{"id" => id} = params) do
    params = resolve_workspace_id(conn, params)

    case Memory.get_scoped_memory(id, params["workspace_id"]) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "memory not found"}})

      memory ->
        purge? = params["purge"] in [true, "true", "1"]

        result =
          if purge?, do: Memory.purge_memory(memory), else: Memory.delete_memory(memory)

        case result do
          {:ok, _} ->
            send_resp(conn, :no_content, "")

          {:error, _} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{errors: %{detail: "delete failed"}})
        end
    end
  end

  # ── Fact extraction (server-side, transcript discarded) ─────────────

  # Per-workspace language pin for stored facts (Settings → Automation).
  # "auto" (nil) keeps the historical behavior: facts in the transcript's language.
  defp summary_language(workspace_id) do
    case Dran.Repo.get(Dran.Workspace, workspace_id) do
      nil -> nil
      ws -> Dran.Workspace.summary_language(ws)
    end
  end

  # "in the language of the transcript" (auto) vs "in Spanish"/"in English" (pinned).
  defp fact_language_clause(nil), do: " in the language of the transcript"
  defp fact_language_clause("es"), do: " in Spanish"
  defp fact_language_clause("en"), do: " in English"
  defp fact_language_clause(_), do: " in the language of the transcript"

  defp extract_facts(transcript, known, params_lang) do
    known_block =
      case known do
        [] ->
          ""

        facts ->
          """
          Facts ALREADY stored in this workspace (do NOT extract these or close
          variants of them — the slots are for NEW knowledge only):
          #{Enum.map_join(facts, "\n", &"- #{&1}")}
          """
      end

    prompt = """
    Extract atomic, self-contained facts from this agent session transcript.
    You are a strict gatekeeper: when in doubt, DISCARD the fact. An empty
    result is a valid outcome.

    MUST-HAVE (all required, drop the fact otherwise):
    - Still true and relevant 3 months from now — durable decisions, stable
      user preferences, project constraints, hard-won technical findings
    - Something the agent could NOT trivially re-derive from the codebase or
      this transcript alone
    - One standalone sentence#{fact_language_clause(params_lang)}

    NEVER store:
    - Secrets, tokens, passwords, or verbatim code
    - Task progress, one-off steps, transient errors, or what a command returned
    - Facts already implied by another fact you extracted (no near-duplicates)

    Self-score each candidate fact with a confidence between 0.0 and 1.0
    answering: "would a teammate in 3 months be glad this was remembered?".
    Facts below #{@min_extraction_confidence} are discarded by the caller.

    #{known_block}Return JSON: {"facts": [{"content": "...", "confidence": 0.0}]}
    with at most 5 facts; empty array if nothing clears the bar.
    """

    payload = %{
      "model" => Inference.chat_model(),
      "messages" => [
        %{"role" => "system", "content" => prompt},
        %{"role" => "user", "content" => truncate(transcript)}
      ],
      "temperature" => 0.2,
      "response_format" => %{"type" => "json_object"}
    }

    case Inference.chat(payload) do
      {:ok, message} ->
        case parse_facts(Map.get(message, "content", "")) do
          {:ok, facts} -> {:ok, facts}
          _ -> {:error, :extraction_failed}
        end

      {:error, _reason} ->
        {:error, :extraction_failed}
    end
  end

  defp parse_facts(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      # Scored shape from the strict prompt: keep content above the confidence bar.
      {:ok, %{"facts" => facts}} when is_list(facts) ->
        kept =
          facts
          |> extract_fact_entries()
          |> Enum.reject(fn %{confidence: c} -> c < @min_extraction_confidence end)
          |> Enum.map(& &1.content)

        {:ok, kept}

      _ ->
        {:error, :invalid_json}
    end
  end

  defp parse_facts(_), do: {:error, :invalid_json}

  # Accepts both {"content": s, "confidence": n} maps and plain strings
  # (legacy / loose models); missing confidence defaults to 1.0 — the model
  # was told to score, but a fact sent unscored is kept rather than guessed away.
  defp extract_fact_entries(facts) do
    facts
    |> Enum.filter(fn
      %{"content" => c} when is_binary(c) and byte_size(c) > 0 -> true
      f when is_binary(f) and byte_size(f) > 0 -> true
      _ -> false
    end)
    |> Enum.map(fn
      %{"content" => c, "confidence" => conf} when is_number(conf) ->
        %{content: String.trim(c), confidence: max(0.0, min(1.0, conf))}

      %{"content" => c} ->
        %{content: String.trim(c), confidence: 1.0}

      f when is_binary(f) ->
        %{content: String.trim(f), confidence: 1.0}
    end)
  end

  defp transcript_text(transcript) when is_binary(transcript), do: transcript

  defp transcript_text(transcript) when is_list(transcript) do
    transcript
    |> Enum.map(fn
      %{"role" => role, "content" => content} -> "#{role}: #{content}"
      %{role: role, content: content} -> "#{role}: #{content}"
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp transcript_text(_), do: nil

  defp truncate(text) when byte_size(text) <= @max_transcript_chars, do: text

  defp truncate(text) do
    binary = String.slice(text, 0, @max_transcript_chars)

    # Avoid splitting a UTF-8 codepoint at the cut
    case String.valid?(binary) do
      true -> binary
      false -> String.slice(text, 0, @max_transcript_chars - 1)
    end
  end

  # ── Shared helpers ───────────────────────────────────────────────────

  defp render_memory(%{memory: memory, score: nil}) do
    render_memory(memory)
  end

  defp render_memory(%{memory: memory, score: score}) do
    memory
    |> render_memory()
    |> Map.put(:score, Float.round(score * 1.0, 6))
  end

  defp render_memory(%Memory{} = m) do
    %{
      id: m.id,
      workspace_id: m.workspace_id,
      content: m.content,
      trust_score: m.trust_score,
      helpful_count: m.helpful_count,
      retrieval_count: m.retrieval_count,
      status: m.status,
      source_session: m.source_session,
      created_by: m.created_by,
      inserted_at: m.inserted_at,
      updated_at: m.updated_at
    }
  end

  defp resolve_workspace_id(conn, params) do
    case params["workspace_id"] || params["workspace"] || conn.query_params["workspace"] do
      nil ->
        params

      workspace_val ->
        workspace = Knowledge.get_workspace_by_slug(workspace_val)

        workspace =
          workspace ||
            case Ecto.UUID.cast(workspace_val) do
              {:ok, uuid} -> Dran.Repo.get(Dran.Workspace, uuid)
              :error -> nil
            end

        if workspace do
          Map.put(params, "workspace_id", workspace.id)
        else
          params
        end
    end
  end

  defp blank?(nil), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""
  defp blank?(_), do: false

  # Row-level authorization: exists AND belongs to the resolved workspace.
  # nil workspace_id (legacy admin/user auth without scope) → not found,
  # consistent with get_scoped_memory/2.
  defp scoped_memory_exists?(_id, nil), do: false

  defp scoped_memory_exists?(id, workspace_id) do
    Memory.get_scoped_memory(id, workspace_id) != nil
  end

  defp parse_limit(nil), do: 10

  defp parse_limit(value) do
    case Integer.parse(to_string(value)) do
      {n, _} when n > 0 -> min(n, 100)
      _ -> 10
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end
end
