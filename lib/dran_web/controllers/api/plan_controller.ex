defmodule DranWeb.API.PlanController do
  @moduledoc """
  La superficie REST de los planes (W2, contrato de superficies).

  El plan es una ENTIDAD con tabla propia (Constraint 7): su lectura pasa por
  `Dran.ContentVisibility` con el scope del lector y su escritura resuelve el
  dueño server-side y traduce el destino `scope` en la misma transacción —
  exactamente como un goal.

  ## El checklist tiene UNA puerta

  `checklist` se acepta al CREAR (los pasos nacen con el plan) y después se
  administra por su propia puerta — `PUT /api/plans/:slug/checklist` (reemplazo
  del array) o `POST /api/checklist/toggle` (tachar/destachar un ítem) — las dos
  con `lock_version` opcional: la reescritura es un read-modify-write, así que
  una mano lenta recibe 409 en vez de pisar a la rápida. `PUT /api/plans/:slug`
  NO toca el checklist (evita las dos puertas para lo mismo: ?14 del contrato
  cerrado).

  El vocabulario del toggle es UNO para los dos contenedores:
  `%{"target" => "plan" | "task", "id" => ..., "index" | "text" => ...}`. El RMW
  vive en el contexto (`Dran.Plans` / `Dran.Tasks`), nunca aquí.
  """

  use DranWeb, :controller

  alias Dran.Plans
  alias Dran.Repo
  alias Dran.Sharing
  alias Dran.Tasks
  alias DranWeb.API.Instance

  @doc "GET /api/plans — planes que el lector puede leer."
  def index(conn, params) do
    opts =
      [scope: Instance.scope_for(conn, :plan)]
      |> maybe_put(:status, params["status"])
      |> maybe_put(:archived, parse_bool(params["archived"]))
      |> maybe_put(:limit, parse_int(params["limit"]))

    json(conn, %{data: Plans.list_plans(opts)})
  end

  @doc "GET /api/plans/:slug — un plan por uuid o slug, con su progreso derivado."
  def show(conn, %{"slug" => segment}) do
    scope = Instance.scope_for(conn, :plan)

    case fetch_plan(segment, scope) do
      nil ->
        not_found(conn, "plan not found")

      plan ->
        json(conn, %{data: plan, progress: Plans.progress(plan)})
    end
  end

  @doc "POST /api/plans — crea un plan (con sus pasos, si vienen)."
  def create(conn, params) do
    {scoped?, scope, params} = Instance.write_scope(conn, params)

    attrs =
      params
      |> Instance.permit_plan_params()
      |> Map.put("checklist", params["checklist"])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
      |> Map.merge(Instance.owner_attrs(conn))

    case create_with_scope(attrs, scoped?, scope, conn.assigns[:user]) do
      {:ok, plan} ->
        conn |> put_status(:created) |> json(%{data: plan})

      {:error, {:scope, message}} ->
        unprocessable(conn, %{detail: message})

      {:error, {:create, %Ecto.Changeset{} = changeset}} ->
        unprocessable(conn, format_errors(changeset))

      {:error, {:create, reason}} ->
        unprocessable(conn, %{detail: to_string(reason)})
    end
  end

  @doc """
  PUT /api/plans/:slug — actualiza los campos del plan (nunca el checklist).
  """
  def update(conn, %{"slug" => segment} = params) do
    scope = Instance.scope_for(conn, :plan)
    {scoped?, write_scope, params} = Instance.write_scope(conn, params)
    attrs = params |> Instance.permit_plan_params() |> Map.delete("visibility")

    case fetch_plan(segment, scope) do
      nil ->
        not_found(conn, "plan not found")

      plan ->
        # W3 (contract auditoria-fixes): resolver la fila no es poseerla.
        if DranWeb.ResourceAuthorization.can_write_row?(scope, plan) do
          case update_with_scope(plan, attrs, scoped?, write_scope, conn.assigns[:user]) do
            {:ok, updated} ->
              json(conn, %{data: updated, progress: Plans.progress(updated)})

            {:error, {:scope, message}} ->
              unprocessable(conn, %{detail: message})

            {:error, {:update, %Ecto.Changeset{} = changeset}} ->
              unprocessable(conn, format_errors(changeset))

            {:error, {:update, reason}} ->
              unprocessable(conn, %{detail: to_string(reason)})
          end
        else
          forbidden(conn)
        end
    end
  end

  @doc "DELETE /api/plans/:slug — borra el plan y sus aristas."
  def delete(conn, %{"slug" => segment}) do
    scope = Instance.scope_for(conn, :plan)

    case fetch_plan(segment, scope) do
      nil ->
        not_found(conn, "plan not found")

      plan ->
        # W3 (contract auditoria-fixes): lo legible-ajeno no se destruye.
        if DranWeb.ResourceAuthorization.can_write_row?(scope, plan) do
          {:ok, _} = Plans.delete_plan(plan)
          send_resp(conn, :no_content, "")
        else
          forbidden(conn)
        end
    end
  end

  @doc "PUT /api/plans/:slug/checklist — reescribe el array de pasos."
  def checklist(conn, %{"slug" => segment} = params) do
    scope = Instance.scope_for(conn, :plan)

    case fetch_plan(segment, scope) do
      nil ->
        not_found(conn, "plan not found")

      plan ->
        # W3 (contract auditoria-fixes): el checklist es escritura de la fila.
        if DranWeb.ResourceAuthorization.can_write_row?(scope, plan) do
          lock = parse_int(params["lock_version"])

          case Plans.set_checklist(plan, params["checklist"] || [], lock_version: lock) do
            {:ok, updated} ->
              json(conn, %{data: updated, progress: Plans.progress(updated)})

            {:error, :stale} ->
              conflict(conn, "plan changed elsewhere — reload and retry")

            {:error, %Ecto.Changeset{} = changeset} ->
              unprocessable(conn, format_errors(changeset))
          end
        else
          forbidden(conn)
        end
    end
  end

  @doc """
  POST /api/checklist/toggle — tacha o destacha UN ítem, de un plan o una task.

  Es la misma operación para los dos contenedores (Constraint 8 y 16): el
  contexto hace el RMW y aquí sólo se elige el contenedor y el rol de lectura.
  """
  def toggle(conn, params) do
    target = params["target"]
    id = params["id"]
    ref = if is_nil(params["index"]), do: params["text"], else: parse_int(params["index"])
    lock = parse_int(params["lock_version"])

    cond do
      target not in ["plan", "task"] ->
        bad_request(conn, "target must be \"plan\" or \"task\"")

      not is_binary(id) ->
        bad_request(conn, "id is required")

      is_nil(ref) ->
        bad_request(conn, "index or text is required")

      true ->
        toggle_in(conn, target, id, ref, lock)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Internals
  # ──────────────────────────────────────────────────────────────────────────

  defp toggle_in(conn, "plan", id, ref, lock) do
    scope = Instance.scope_for(conn, :plan)

    case fetch_plan(id, scope) do
      nil -> not_found(conn, "plan not found")
      plan -> toggle_result(conn, Plans.toggle_checklist(plan, ref, lock_version: lock))
    end
  end

  defp toggle_in(conn, "task", id, ref, lock) do
    scope = Instance.scope_for(conn, :goal)

    case Tasks.get_task(id, scope: scope) do
      nil -> not_found(conn, "task not found")
      task -> toggle_result(conn, Tasks.toggle_checklist(task, ref, lock_version: lock))
    end
  end

  defp toggle_result(conn, {:ok, resource}), do: json(conn, %{data: resource})

  defp toggle_result(conn, {:error, :stale}),
    do: conflict(conn, "checklist changed elsewhere — reload and retry")

  defp toggle_result(conn, {:error, :not_found}),
    do: not_found(conn, "checklist item not found")

  defp toggle_result(conn, {:error, %Ecto.Changeset{} = changeset}),
    do: unprocessable(conn, format_errors(changeset))

  defp fetch_plan(segment, scope) do
    Instance.fetch_segment(
      segment,
      fn uuid -> Plans.get_plan(uuid, scope: scope) end,
      fn slug -> Plans.get_plan_by_slug(slug, scope: scope) end
    )
  end

  # La IDENTIDAD viaja hasta la frontera: una credencial atada a un destino (el
  # token de un grupo) sólo puede honrar el suyo (`apply_scope/4`).
  defp create_with_scope(attrs, scoped?, scope, identity) do
    Repo.transaction(fn ->
      case Plans.create_plan(attrs) do
        {:ok, plan} -> translate_scope(plan, scope, scoped?, identity)
        {:error, reason} -> Repo.rollback({:create, reason})
      end
    end)
  end

  defp update_with_scope(plan, attrs, scoped?, scope, identity) do
    Repo.transaction(fn ->
      case Plans.update_plan(plan, attrs) do
        {:ok, updated} -> translate_scope(updated, scope, scoped?, identity)
        {:error, reason} -> Repo.rollback({:update, reason})
      end
    end)
  end

  defp translate_scope(plan, _scope, false, _identity), do: plan

  defp translate_scope(plan, scope, true, identity) do
    case Sharing.apply_scope(plan, scope, :plan, identity) do
      {:ok, plan} -> plan
      {:error, message} -> Repo.rollback({:scope, message})
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(_), do: nil

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_), do: nil
end
