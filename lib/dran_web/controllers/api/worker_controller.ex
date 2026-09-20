defmodule DranWeb.API.WorkerController do
  @moduledoc """
  REST surface for the autonomous workers (curator, link_gardener, graph_rag).

  Parity with the plugin tools `dran_start_worker` /
  `dran_get_worker_session`: start returns immediately with a session id and
  the caller polls until the session reaches a terminal status.

  Workers write pages, so starting one is a WRITE operation — the router
  enforces `write` access on the key.
  """

  use DranWeb, :controller

  alias Dran.Repo
  alias Dran.Worker

  @worker_types ~w(curator link_gardener graph_rag)
  @terminal_statuses ~w(done failed)
  # Whitelist de opts aceptadas: ver normalize_opts/1 (sin String.to_atom
  # sobre input del cliente).
  @worker_opt_keys ~w(limit focus depth max_pages force)a

  @doc "POST /api/workers — start a worker session."
  def create(conn, params) do
    params = Map.put(params, "workspace_id", DranWeb.API.Instance.instance_context_id())
    workspace_id = params["workspace_id"]
    worker_type = params["worker_type"] || params["type"]
    input = params["input"] || ""

    cond do
      is_nil(workspace_id) ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: %{detail: "workspace query param is required"}})

      worker_type not in @worker_types ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          errors: %{
            detail: "worker_type must be one of #{Enum.join(@worker_types, ", ")}"
          }
        })

      true ->
        case start_worker(worker_type, input, workspace_id, params["opts"]) do
          {:ok, session} ->
            conn
            |> put_status(:created)
            |> json(%{data: render_session(session, [])})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: %{detail: "failed to start worker: #{inspect(reason)}"}})
        end
    end
  end

  @doc "GET /api/workers/:id — poll a worker session (status, summary, steps)."
  def show(conn, %{"id" => session_id} = params) do
    params = Map.put(params, "workspace_id", DranWeb.API.Instance.instance_context_id())

    case Ecto.UUID.cast(session_id) do
      {:ok, id} ->
        case Repo.get(Worker.Session, id) |> preload_steps() do
          nil ->
            conn
            |> put_status(:not_found)
            |> json(%{errors: %{detail: "worker session not found"}})

          session ->
            if params["workspace_id"] && session.workspace_id != params["workspace_id"] do
              # Row-level scoping: a key for another workspace must not poll
              # this session (same posture as get_scoped_memory).
              conn
              |> put_status(:not_found)
              |> json(%{errors: %{detail: "worker session not found"}})
            else
              json(conn, %{data: render_session(session, session.steps)})
            end
        end

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: %{detail: "invalid session_id"}})
    end
  end

  def show(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "session id is required"}})
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Slug/UUID → workspace_id in the params, same convention as the other API
  # controllers (MemoryController.resolve_workspace_id/2).
  defp start_worker("curator", input, workspace_id, opts),
    do: Worker.Curator.run(input, workspace_id, normalize_opts(opts))

  defp start_worker("link_gardener", input, workspace_id, opts),
    do: Worker.LinkGardener.run(input, workspace_id, normalize_opts(opts))

  defp start_worker("graph_rag", input, workspace_id, opts),
    do: Worker.GraphRag.run(input, workspace_id, normalize_opts(opts))

  # The tool accepts a map of opts; the workers expect a keyword list.
  # Keys are whitelisted — `String.to_atom/1` on client input would let a
  # caller grow the atom table (the reason sobelow flags it as Medium).
  defp normalize_opts(nil), do: []

  defp normalize_opts(opts) when is_list(opts) do
    Enum.filter(opts, fn
      {k, _v} when is_atom(k) -> k in @worker_opt_keys
      _ -> false
    end)
  end

  defp normalize_opts(opts) when is_map(opts) do
    for {k, v} <- opts, key = worker_opt_key(k), key != nil, do: {key, v}
  end

  defp normalize_opts(_), do: []

  defp worker_opt_key(key) when is_atom(key), do: if(key in @worker_opt_keys, do: key)

  defp worker_opt_key(key) when is_binary(key),
    do: Enum.find(@worker_opt_keys, &(Atom.to_string(&1) == key))

  defp worker_opt_key(_), do: nil

  defp preload_steps(nil), do: nil
  defp preload_steps(session), do: Repo.preload(session, :steps)

  defp render_session(session, steps) do
    ordered = Enum.sort_by(steps || [], & &1.step_number)

    %{
      id: session.id,
      worker_type: session.worker_type,
      status: session.status,
      terminal: session.status in @terminal_statuses,
      input: session.input,
      summary: session.summary,
      pages_created: session.pages_created,
      steps_count: session.steps_count,
      track_url: "/workers/#{session.worker_type}/#{session.id}",
      inserted_at: session.inserted_at,
      completed_at: session.completed_at,
      steps:
        Enum.map(ordered, fn step ->
          %{
            step_number: step.step_number,
            tool_name: step.tool_name,
            status: Map.get(step.tool_result || %{}, "status", "pending")
          }
        end)
    }
  end
end
