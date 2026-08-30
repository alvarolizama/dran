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
  @max_facts_per_ingest 20

  @doc "POST /api/memory — store a fact (idempotent per workspace)."
  def create(conn, params) do
    params = resolve_workspace_id(conn, params)
    user = conn.assigns[:user]

    attrs = %{
      "workspace_id" => params["workspace_id"],
      "content" => params["content"],
      "source_session" => params["source_session"],
      "created_by" => Auth.resolve_created_by(user)
    }

    case Memory.add(attrs) do
      {:ok, memory, :created} ->
        conn
        |> put_status(:created)
        |> json(%{data: memory, duplicate: false})

      {:ok, memory, :duplicate} ->
        json(conn, %{data: memory, duplicate: true})

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

        case extract_facts(transcript) do
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
                "created_by" => Auth.resolve_created_by(user)
              }

              case Memory.add(attrs) do
                {:ok, memory, :created} ->
                  %{acc | created: acc.created + 1, facts: [memory.content | acc.facts]}

                {:ok, _existing, :duplicate} ->
                  %{acc | duplicates: acc.duplicates + 1}

                {:error, _} ->
                  acc
              end
            end)
            |> then(fn result -> json(conn, result) end)
        end
    end
  end

  @doc "DELETE /api/memory/:id?workspace= — soft-remove a fact (superseded)."
  def delete(conn, %{"id" => id} = params) do
    params = resolve_workspace_id(conn, params)

    case Memory.get_scoped_memory(id, params["workspace_id"]) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "memory not found"}})

      memory ->
        case Memory.delete_memory(memory) do
          {:ok, _} ->
            send_resp(conn, :no_content, "")

          {:error, _} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{errors: %{detail: "update failed"}})
        end
    end
  end

  # ── Fact extraction (server-side, transcript discarded) ─────────────

  defp extract_facts(transcript) do
    prompt = """
    Extract atomic, self-contained facts from this agent session transcript.
    Rules:
    - Each fact is one standalone sentence in the language of the transcript
    - Include durable knowledge only: decisions, preferences, project facts, technical findings
    - NO secrets, tokens, passwords, or verbatim code
    - Return JSON: {"facts": ["...", "..."]} with at most 20 facts; empty array if nothing durable
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
      {:ok, %{"facts" => facts}} when is_list(facts) ->
        {:ok, Enum.filter(facts, fn f -> is_binary(f) and String.trim(f) != "" end)}

      _ ->
        {:error, :invalid_json}
    end
  end

  defp parse_facts(_), do: {:error, :invalid_json}

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
  defp blank?(""), do: true
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
