defmodule DranWeb.API.TaskController do
  @moduledoc """
  La superficie REST de las tasks (W2, contrato de superficies).

  Una task NO declara visibilidad: la hereda de su goal (Constraint 9), así que
  toda lectura entra por `Dran.Tasks` con `scope:` — el join al goal filtrado
  hace imposible enumerar tasks de un goal ajeno privado.

  ## Una sola puerta para la columna y para el goal

  `status`, `position`, `goal_id` y `lock_version` NO son campos de escritura de
  esta superficie (Constraint 13): cambiar de columna o de goal pasa por
  `POST /api/tasks/:id/move`, que es el único camino que respeta el orden,
  renumera y recomputa el progreso derivado de los DOS goals. El `update` sólo
  toca campos de contenido (título, cuerpo, prioridad, fecha, asignado,
  checklist, recurrencia, archivado).

  ## La captura rápida cae en la bandeja

  Sin `goal`, una task nueva aterriza en el **goal bandeja** del dueño de la
  credencial, creado perezosamente (`Dran.Goals.ensure_inbox/1`) — la puerta que
  hace sostenible el `goal_id NOT NULL` del motor (Constraint 9).
  """

  use DranWeb, :controller

  alias Dran.Goals
  alias Dran.Tasks
  alias DranWeb.API.Instance

  @doc "GET /api/tasks — tasks legibles, filtrables por goal, columna y asignado."
  def index(conn, params) do
    scope = Instance.scope_for(conn, :goal)

    case goal_filter(params["goal"], scope) do
      # Un goal pedido que no es legible no enumera NADA (y no se filtra por un
      # slug en la columna uuid, que reventaría el cast).
      :none ->
        json(conn, %{data: []})

      goal_id ->
        opts =
          [scope: scope]
          |> maybe_put(:goal_id, goal_id)
          |> maybe_put(:status, params["status"])
          |> maybe_put(:assignee_id, parse_int(params["assignee"]))
          |> maybe_put(:archived, parse_bool(params["archived"]))
          |> maybe_put(:limit, parse_int(params["limit"]))

        json(conn, %{data: Tasks.list_tasks(opts)})
    end
  end

  @doc "GET /api/tasks/:id — una task por uuid."
  def show(conn, %{"id" => id}) do
    scope = Instance.scope_for(conn, :goal)

    case Tasks.get_task(id, scope: scope) do
      nil -> not_found(conn, "task not found")
      task -> json(conn, %{data: task})
    end
  end

  @doc "POST /api/tasks — crea una task; sin `goal` cae en la bandeja del dueño."
  def create(conn, params) do
    scope = Instance.scope_for(conn, :goal)

    case resolve_goal_or_inbox(conn, params["goal"], scope) do
      {:error, :no_owner} ->
        unprocessable(conn, %{
          detail: "the credential has no owner to own the inbox goal: pass an explicit `goal`"
        })

      {:error, :not_found} ->
        not_found(conn, "goal not found")

      {:ok, goal} ->
        attrs = params |> Instance.permit_task_params() |> Map.put("goal_id", goal.id)

        case Tasks.create_task(attrs) do
          {:ok, task} ->
            conn |> put_status(:created) |> json(%{data: task})

          {:error, %Ecto.Changeset{} = changeset} ->
            unprocessable(conn, format_errors(changeset))
        end
    end
  end

  @doc "POST /api/capture — captura rápida: una task en el goal bandeja."
  def capture(conn, params) do
    create(conn, params)
  end

  @doc """
  PUT /api/tasks/:id — actualiza el contenido de una task.

  El whitelist excluye `status`, `position`, `goal_id` y `lock_version`: la
  columna y el goal se mueven por `/move` (Constraint 13).
  """
  def update(conn, %{"id" => id} = params) do
    scope = Instance.scope_for(conn, :goal)

    case Tasks.get_task(id, scope: scope) do
      nil ->
        not_found(conn, "task not found")

      task ->
        # W3 (contract auditoria-fixes): la task no lleva dueño propio — el
        # dueño es el de su goal (Constraint 12), que ya pasó el scope.
        if task_writable?(task, scope) do
          case Tasks.update_task(task, Instance.permit_task_params(params)) do
            {:ok, updated} ->
              json(conn, %{data: updated})

            {:error, %Ecto.Changeset{} = changeset} ->
              unprocessable(conn, format_errors(changeset))
          end
        else
          forbidden(conn)
        end
    end
  end

  @doc """
  POST /api/tasks/:id/move — columna, posición y/o goal, atómico.

  La task se resuelve DENTRO del scope y el goal destino TAMBIÉN: mover una task
  a un goal que el lector no puede leer sería escribir dentro de contenido ajeno
  (fail-closed 404). Un `lock_version` desfasado es 409, nunca una
  sobrescritura silenciosa.
  """
  def move(conn, %{"id" => id} = params) do
    scope = Instance.scope_for(conn, :goal)

    with %{} = task <- Tasks.get_task(id, scope: scope),
         # W3 (contract auditoria-fixes): mover es escribir — el dueño manda.
         true <- task_writable?(task, scope) || {:error, :forbidden},
         {:ok, goal_id} <- target_goal_id(params["goal"], task, scope) do
      attrs =
        %{
          "status" => params["status"],
          "goal_id" => goal_id,
          "before_id" => params["before_id"],
          "after_id" => params["after_id"],
          "lock_version" => params["lock_version"]
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      case Tasks.move_task(task, attrs) do
        {:ok, moved} ->
          json(conn, %{data: moved})

        {:error, :stale} ->
          conflict(conn, "task was moved elsewhere — reload and retry")

        {:error, %Ecto.Changeset{} = changeset} ->
          unprocessable(conn, format_errors(changeset))

        {:error, reason} ->
          unprocessable(conn, %{detail: to_string(reason)})
      end
    else
      nil -> not_found(conn, "task not found")
      {:error, :not_found} -> not_found(conn, "goal not found")
      {:error, :forbidden} -> forbidden(conn)
    end
  end

  @doc "DELETE /api/tasks/:id — borra la task y sus aristas."
  def delete(conn, %{"id" => id}) do
    scope = Instance.scope_for(conn, :goal)

    case Tasks.get_task(id, scope: scope) do
      nil ->
        not_found(conn, "task not found")

      task ->
        # W3 (contract auditoria-fixes): lo legible-ajeno no se destruye.
        if task_writable?(task, scope) do
          {:ok, _} = Tasks.delete_task(task)
          send_resp(conn, :no_content, "")
        else
          forbidden(conn)
        end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Internals
  # ──────────────────────────────────────────────────────────────────────────

  # Sin `goal` en el body, la captura va a la bandeja del dueño de la
  # credencial. Una credencial sin dueño (token admin legacy) no puede tener
  # bandeja: falla cerrado en vez de inventar un dueño.
  defp resolve_goal_or_inbox(conn, nil, _scope) do
    case Instance.owner_attrs(conn) do
      %{"owner_user_id" => _} -> Goals.ensure_inbox(conn.assigns[:user])
      %{} -> {:error, :no_owner}
    end
  end

  defp resolve_goal_or_inbox(conn, "", scope), do: resolve_goal_or_inbox(conn, nil, scope)

  defp resolve_goal_or_inbox(_conn, segment, scope) when is_binary(segment) do
    case fetch_goal(segment, scope) do
      nil -> {:error, :not_found}
      goal -> {:ok, goal}
    end
  end

  defp resolve_goal_or_inbox(_conn, _goal, _scope), do: {:error, :not_found}

  # El goal destino de un move: ausente = quedarse donde está.
  defp target_goal_id(nil, _task, _scope), do: {:ok, nil}
  defp target_goal_id("", _task, _scope), do: {:ok, nil}

  defp target_goal_id(segment, _task, scope) when is_binary(segment) do
    case fetch_goal(segment, scope) do
      nil -> {:error, :not_found}
      goal -> {:ok, goal.id}
    end
  end

  defp target_goal_id(_segment, _task, _scope), do: {:error, :not_found}

  # W3 (contract auditoria-fixes): la task NO lleva dueño propio — lo hereda de
  # su goal (Constraint 12). El gate de fila corre sobre el goal contenedor:
  # `:all` escribe, `{:group, _}` escribe lo de su grupo y `{:reader, id}`
  # exige que el goal sea suyo.
  defp task_writable?(task, scope) do
    case Tasks.get_task_goal(task) do
      nil -> false
      goal -> DranWeb.ResourceAuthorization.can_write_row?(scope, goal)
    end
  end

  defp fetch_goal(segment, scope) do
    Instance.fetch_segment(
      segment,
      fn uuid -> Goals.get_goal(uuid, scope: scope) end,
      fn slug -> Goals.get_goal_by_slug(slug, scope: scope) end
    )
  end

  # El filtro por goal del índice: un goal fuera del scope no enumera nada (y no
  # se filtra por un slug en la columna uuid, que reventaría el cast).
  defp goal_filter(nil, _scope), do: nil
  defp goal_filter("", _scope), do: nil

  defp goal_filter(segment, scope) when is_binary(segment) do
    case fetch_goal(segment, scope) do
      nil -> :none
      goal -> goal.id
    end
  end

  defp goal_filter(_segment, _scope), do: :none

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
