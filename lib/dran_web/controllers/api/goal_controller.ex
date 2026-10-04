defmodule DranWeb.API.GoalController do
  @moduledoc """
  La superficie REST de los goals (W2, contrato de superficies).

  * la LECTURA pasa por `Dran.ContentVisibility` con el scope del lector
    (Constraint 1): un goal ajeno privado es 404, nunca 403 — la existencia no
    se filtra;
  * la ESCRITURA resuelve el dueño server-side (Constraint 3) y traduce el
    destino declarado (`scope`) en `visibility` + `content_shares` DENTRO de la
    misma transacción (Constraint 5): un destino que no se puede honrar revierte
    la fila y devuelve 422, nunca un `private` en silencio;
  * `:slug` en la ruta es id-o-slug (Constraint 11).
  """

  use DranWeb, :controller

  alias Dran.Goals
  alias Dran.Repo
  alias Dran.Sharing
  alias Dran.Tasks
  alias DranWeb.API.Instance

  @doc "GET /api/goals — goals que el lector puede leer."
  def index(conn, params) do
    opts =
      [scope: Instance.scope_for(conn, :goal)]
      |> maybe_put(:status, params["status"])
      |> maybe_put(:archived, parse_bool(params["archived"]))
      |> maybe_put(:limit, parse_int(params["limit"]))

    json(conn, %{data: Goals.list_goals(opts)})
  end

  @doc "GET /api/goals/:slug — un goal por uuid o slug."
  def show(conn, %{"slug" => segment}) do
    scope = Instance.scope_for(conn, :goal)

    case fetch_goal(segment, scope) do
      nil -> not_found(conn, "goal not found")
      goal -> json(conn, %{data: goal})
    end
  end

  @doc """
  GET /api/goals/:slug/tasks — las tasks del goal.

  La lectura entra por el goal legible: si el goal está fuera del scope, la
  respuesta es 404 y no se enumeran sus tasks.
  """
  def tasks(conn, %{"slug" => segment}) do
    scope = Instance.scope_for(conn, :goal)

    case fetch_goal(segment, scope) do
      nil ->
        not_found(conn, "goal not found")

      goal ->
        json(conn, %{data: Tasks.list_tasks_for_goal(goal, scope: scope)})
    end
  end

  @doc "POST /api/goals — crea un goal con el dueño de la credencial."
  def create(conn, params) do
    {scoped?, scope, params} = Instance.pop_write_scope(params)

    attrs =
      params
      |> Instance.permit_goal_params()
      |> Map.merge(Instance.owner_attrs(conn))

    case create_with_scope(attrs, scoped?, scope) do
      {:ok, goal} ->
        conn |> put_status(:created) |> json(%{data: goal})

      {:error, {:scope, message}} ->
        unprocessable(conn, %{detail: message})

      {:error, {:create, %Ecto.Changeset{} = changeset}} ->
        unprocessable(conn, format_errors(changeset))

      {:error, {:create, reason}} ->
        unprocessable(conn, %{detail: to_string(reason)})
    end
  end

  @doc """
  PUT /api/goals/:slug — actualiza un goal.

  `owner_user_id` no es escribible (Constraint 3); un `scope` presente re-traduce
  la visibilidad y los shares de la fila (Constraint 5).
  """
  def update(conn, %{"slug" => segment} = params) do
    scope = Instance.scope_for(conn, :goal)
    {scoped?, write_scope, params} = Instance.pop_write_scope(params)
    attrs = params |> Instance.permit_goal_params() |> Map.delete("visibility")

    case fetch_goal(segment, scope) do
      nil ->
        not_found(conn, "goal not found")

      goal ->
        case update_with_scope(goal, attrs, scoped?, write_scope) do
          {:ok, updated} ->
            json(conn, %{data: updated})

          {:error, {:scope, message}} ->
            unprocessable(conn, %{detail: message})

          {:error, {:update, %Ecto.Changeset{} = changeset}} ->
            unprocessable(conn, format_errors(changeset))

          {:error, {:update, reason}} ->
            unprocessable(conn, %{detail: to_string(reason)})
        end
    end
  end

  @doc "DELETE /api/goals/:slug — borra el goal, sus tasks y sus aristas."
  def delete(conn, %{"slug" => segment}) do
    scope = Instance.scope_for(conn, :goal)

    case fetch_goal(segment, scope) do
      nil ->
        not_found(conn, "goal not found")

      goal ->
        {:ok, _} = Goals.delete_goal(goal)
        send_resp(conn, :no_content, "")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Internals
  # ──────────────────────────────────────────────────────────────────────────

  defp fetch_goal(segment, scope) do
    Instance.fetch_segment(
      segment,
      fn uuid -> Goals.get_goal(uuid, scope: scope) end,
      fn slug -> Goals.get_goal_by_slug(slug, scope: scope) end
    )
  end

  # El insert y la traducción del `scope` van en UNA transacción: un destino
  # inválido (grupo inexistente o ajeno) revierte el goal — nada de huérfanos.
  defp create_with_scope(attrs, scoped?, scope) do
    Repo.transaction(fn ->
      case Goals.create_goal(attrs) do
        {:ok, goal} -> translate_scope(goal, scope, scoped?)
        {:error, reason} -> Repo.rollback({:create, reason})
      end
    end)
  end

  defp update_with_scope(goal, attrs, scoped?, scope) do
    Repo.transaction(fn ->
      case Goals.update_goal(goal, attrs) do
        {:ok, updated} -> translate_scope(updated, scope, scoped?)
        {:error, reason} -> Repo.rollback({:update, reason})
      end
    end)
  end

  defp translate_scope(goal, _scope, false), do: goal

  defp translate_scope(goal, scope, true) do
    case Sharing.apply_scope(goal, scope, :goal) do
      {:ok, goal} -> goal
      {:error, message} -> Repo.rollback({:scope, message})
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(_), do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_), do: nil
end
