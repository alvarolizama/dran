defmodule Dran.Tasks do
  @moduledoc """
  El contexto de tasks — CRUD, board y el **move por los dos ejes**.

  Toda task vive bajo un goal (`goal_id NOT NULL` en el motor) y NO declara
  visibilidad: las lecturas con `scope:` la derivan del goal por join +
  `Dran.ContentVisibility.filter/3` (Constraint 12 / F2).

  ## Move

  `move_task/2` mueve una task por los dos ejes —entre goals y dentro del
  goal— como un `UPDATE` atómico en transacción que respeta `lock_version`;
  al terminar recomputa (lee) el progreso derivado de AMBOS goals.
  """

  import Ecto.Query, warn: false

  alias Dran.Repo
  alias Dran.Goals.Goal
  alias Dran.Tasks.Task

  # ──────────────────────────────────────────────────────────────────────────
  # Lectura (visibilidad derivada del goal)
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Lista tasks con scope de lectura heredado del goal.

  Opts: `:scope` (default `:all`), `:goal_id`, `:status`, `:assignee_id`,
  `:archived`, `:limit`.
  """
  def list_tasks(opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)
    goal_id = Keyword.get(opts, :goal_id)
    status = Keyword.get(opts, :status)
    assignee_id = Keyword.get(opts, :assignee_id)
    archived = Keyword.get(opts, :archived, false)
    limit = Keyword.get(opts, :limit, 500)

    visible_goals = visible_goals_query(scope)

    query =
      from t in Task,
        join: g in subquery(visible_goals),
        on: g.id == t.goal_id,
        where: t.archived == ^archived,
        order_by: [asc: t.position, asc: t.inserted_at],
        limit: ^limit,
        select: t

    query = if goal_id, do: where(query, [t, _g], t.goal_id == ^goal_id), else: query
    query = if status, do: where(query, [t, _g], t.status == ^status), else: query

    query =
      if is_integer(assignee_id),
        do: where(query, [t, _g], t.assignee_id == ^assignee_id),
        else: query

    Repo.all(query)
  end

  @doc """
  Trae una task por id. La variante con `scope:` hereda la visibilidad del
  goal; la variante sin opts es interna (sin filtro).
  """
  def get_task(id) do
    if valid_uuid?(id), do: Repo.get(Task, id), else: nil
  end

  def get_task(id, opts) when is_list(opts) do
    scope = Keyword.get(opts, :scope, :all)

    with true <- valid_uuid?(id) do
      visible_goals = visible_goals_query(scope)

      Repo.one(
        from t in Task,
          join: g in subquery(visible_goals),
          on: g.id == t.goal_id,
          where: t.id == ^id,
          select: t
      )
    else
      _ -> nil
    end
  end

  @doc "Trae una task por slug dentro de un goal."
  def get_task_by_slug(slug, goal_id) when is_binary(slug) and is_binary(goal_id) do
    Repo.one(from t in Task, where: t.slug == ^slug and t.goal_id == ^goal_id)
  end

  @doc """
  Tasks de un goal, en orden de board. Con `scope:` valida que el goal sea
  legible antes de devolver sus tasks.
  """
  def list_tasks_for_goal(%Goal{} = goal, opts \\ []) do
    list_tasks(Keyword.put(opts, :goal_id, goal.id))
  end

  @doc """
  Board de un goal: `%{"backlog" => [task, ...], ...}` con todas las columnas,
  aun vacías.
  """
  def list_board(goal_id, opts \\ []) when is_binary(goal_id) do
    tasks = list_tasks(Keyword.put(opts, :goal_id, goal_id))

    Task.statuses()
    |> Map.new(fn status -> {status, Enum.filter(tasks, &(&1.status == status))} end)
  end

  @doc "Changeset para formularios."
  def change_task(%Task{} = task, attrs \\ %{}), do: Task.update_changeset(task, attrs)

  @doc "Max position de una columna (0 si está vacía)."
  def max_position(goal_id, status) when is_binary(goal_id) and is_binary(status) do
    Repo.one(
      from t in Task,
        where: t.goal_id == ^goal_id and t.status == ^status,
        select: coalesce(max(t.position), 0)
    )
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Escritura
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Crea una task. Sin `goal_id` no se puede: el changeset lo exige y el motor
  (`NOT NULL` + FK) lo garantiza aunque se saltee el changeset.
  """
  def create_task(attrs) do
    attrs
    |> ensure_slug()
    |> Task.create_changeset()
    |> Repo.insert()
  end

  @doc "Actualiza una task (el slug se regenera si cambia el título)."
  def update_task(%Task{} = task, attrs) do
    attrs
    |> Dran.Slug.inject_update(task,
      field: "title",
      fallback: "task",
      lookup: &get_task_by_slug(&1, task.goal_id)
    )
    |> then(&(task |> Task.update_changeset(&1) |> Repo.update()))
  end

  @doc """
  La edición COMPLETA de una task desde un formulario: contenido, pasos y estado.

  Es el caso de uso del modal de edición — el MISMO en el board y en el detalle
  del goal — así que vive acá y no duplicado en las dos LiveViews. Primero valida
  (sin escribir) y después escribe cada campo por su puerta, en un orden que
  respeta el bloqueo optimista:

    0. se valida el estado y el contenido: un select forjado o un título vacío
       devuelven error SIN dejar media edición escrita;
    1. los pasos por `set_checklist/3` con el `lock_version` del FORM — es el RMW,
       así que acá se detecta que otra mano reescribió el array: un form viejo no
       escribe NADA más;
    2. el contenido (título, prioridad, fecha) por `update_task/2`: no toca el lock;
    3. el estado por `move_task/2` con el lock FRESCO que dejó el paso 1: mover la
       columna mantiene las posiciones de las dos y no puede nacer viejo.

  `checklist: nil` (form sin editor de pasos) y un `status` `nil` o igual al
  actual dejan su paso en no-op; un estado fuera del vocabulario devuelve
  `{:error, :invalid_status}`.
  """
  def save_edit(%Task{} = task, attrs, opts \\ []) do
    status = Keyword.get(opts, :status) || attr(attrs, "status")
    content = content_attrs(attrs)

    with :ok <- validate_status(status),
         :ok <- validate_content(task, content),
         {:ok, checked} <-
           maybe_set_checklist(
             task,
             Keyword.get(opts, :checklist),
             normalize_lock(Keyword.get(opts, :lock_version))
           ),
         {:ok, updated} <- update_task(checked, content),
         {:ok, moved} <- maybe_move_status(updated, status) do
      {:ok, moved}
    end
  end

  @doc "Borra una task y sus aristas (no deja nodos muertos en el grafo)."
  def delete_task(%Task{} = task) do
    Repo.transaction(fn ->
      Dran.Relation.delete_edges("task", task.id)
      Repo.delete!(task)
    end)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Checklist — el RMW con bloqueo optimista
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Reescribe el checklist completo de la task (array ordenado, forma canónica).

  Cualquier entrada se normaliza (`Dran.Checklist.cast/1`). Con `lock_version:`
  se exige esa versión: la edición del checklist es un RMW, así que una mano
  lenta recibe `{:error, :stale}` en vez de pisar a la rápida.
  """
  def set_checklist(%Task{} = task, items, opts \\ []) do
    attrs = %{"checklist" => items}

    attrs
    |> maybe_put_lock(opts)
    |> then(&Task.checklist_changeset(task, &1))
    |> Repo.update(stale_error_field: :lock_version)
    |> normalize_lock_result()
  end

  @doc """
  Tacha o destacha UN ítem del checklist, por índice (0-based) o por texto.

  La posición se busca sobre el array ACTUAL de la task y la escritura respeta
  `lock_version` (la operación no vive en el controlador ni en la UI).
  """
  def toggle_checklist(%Task{} = task, ref, opts \\ []) do
    case Dran.Checklist.toggle(task.checklist, ref) do
      {:ok, items} -> set_checklist(task, items, opts)
      :error -> {:error, :not_found}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Move — los dos ejes con lock_version
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Mueve una task: estado, columna y/o goal, en un `UPDATE` atómico.

  `attrs` acepta (claves string o átomo):

    * `"status"` — nueva columna (default: la actual)
    * `"goal_id"` — goal destino (default: el actual) → mueve entre goals
    * `"position"` / `"before_id"` / `"after_id"` — orden dentro de la columna
    * `"lock_version"` — versión esperada (bloqueo optimista)

  Devuelve `{:ok, task}`, `{:error, :stale}` si el `lock_version` no coincide,
  o `{:error, changeset}`. Al terminar recomputa el progreso derivado de los
  DOS goals involucrados (el de origen y el de destino).
  """
  def move_task(%Task{} = task, attrs) when is_map(attrs) do
    target_goal_id = attr(attrs, "goal_id") || task.goal_id
    new_status = attr(attrs, "status") || task.status
    lock_version = attr(attrs, "lock_version") || task.lock_version
    before_id = attr(attrs, "before_id")
    after_id = attr(attrs, "after_id")

    Repo.transaction(fn ->
      position =
        compute_insert_position(target_goal_id, new_status, before_id, after_id)

      changeset =
        Task.move_changeset(task, %{
          "goal_id" => target_goal_id,
          "status" => new_status,
          "position" => position,
          "lock_version" => lock_version
        })

      case Repo.update(changeset, stale_error_field: :lock_version) do
        {:ok, updated} ->
          renumber_column(target_goal_id, new_status)

          if target_goal_id != task.goal_id do
            renumber_column(task.goal_id, task.status)
          end

          # El progreso se DERIVA: recomputarlo es leerlo para ambos goals.
          _ = Dran.Goals.progress(task.goal_id)
          _ = Dran.Goals.progress(target_goal_id)

          {:ok, updated}

        {:error, %Ecto.Changeset{} = cs} ->
          if cs.errors[:lock_version] do
            Repo.rollback(:stale)
          else
            {:error, cs}
          end
      end
    end)
    |> case do
      {:ok, {:ok, updated}} -> {:ok, updated}
      {:ok, {:error, cs}} -> {:error, cs}
      {:error, :stale} -> {:error, :stale}
      {:error, other} -> {:error, other}
    end
  end

  # Move a una nueva columna (sin cambiar de goal).
  def move_task(%Task{} = task, new_status) when is_binary(new_status) do
    move_task(task, %{"status" => new_status})
  end

  # ── Posicionamiento (gap de 100) ──────────────────────────────────────────

  defp compute_insert_position(goal_id, status, before_id, after_id) do
    cond do
      is_binary(before_id) ->
        before = Repo.get(Task, before_id)
        prev = prev_position(goal_id, status, before.position)
        div(prev + before.position, 2)

      is_binary(after_id) ->
        after_task = Repo.get(Task, after_id)
        nxt = next_position(goal_id, status, after_task.position)
        div(after_task.position + nxt, 2)

      true ->
        max_position(goal_id, status) + 100
    end
  end

  defp prev_position(goal_id, status, current_pos) do
    Repo.one(
      from t in Task,
        where: t.goal_id == ^goal_id and t.status == ^status and t.position < ^current_pos,
        select: coalesce(max(t.position), 0)
    )
  end

  defp next_position(goal_id, status, current_pos) do
    Repo.one(
      from t in Task,
        where: t.goal_id == ^goal_id and t.status == ^status and t.position > ^current_pos,
        select: min(t.position)
    )
    |> case do
      nil -> current_pos + 100
      pos -> pos
    end
  end

  # Renumera la columna con gap de 100 solo si el hueco mínimo bajó de 10.
  defp renumber_column(goal_id, status) do
    tasks =
      from(t in Task,
        where: t.goal_id == ^goal_id and t.status == ^status,
        order_by: [asc: t.position, asc: t.inserted_at],
        select: %{id: t.id, position: t.position}
      )
      |> Repo.all()

    case min_gap(Enum.map(tasks, & &1.position)) do
      gap when is_integer(gap) and gap < 10 ->
        {updates, _acc} =
          Enum.map_reduce(tasks, 100, fn task, pos -> {{task.id, pos}, pos + 100} end)

        Enum.each(updates, fn {id, pos} ->
          Repo.update_all(from(t in Task, where: t.id == ^id), set: [position: pos])
        end)

      _ ->
        :ok
    end
  end

  defp min_gap([]), do: nil
  defp min_gap([_single]), do: nil

  defp min_gap(positions) do
    positions
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> b - a end)
    |> Enum.min()
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  # Mete el goal visible en una subquery para que `filter/3` corra sobre el
  # goal (que es quien tiene `visibility` + `owner_user_id`) y el join no
  # pueda fugar una task de un goal ajeno.
  defp visible_goals_query(scope) do
    from(g in Goal, select: g)
    |> Dran.ContentVisibility.filter(scope, :goal)
  end

  defp ensure_slug(attrs) do
    case Dran.Slug.fetch_attr(attrs, "goal_id") do
      goal_id when is_binary(goal_id) ->
        Dran.Slug.inject_create(attrs,
          field: "title",
          fallback: "task",
          taken?: fn candidate -> get_task_by_slug(candidate, goal_id) != nil end
        )

      _ ->
        attrs
    end
  end

  defp attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, safe_atom(key))
  end

  defp maybe_put_lock(attrs, opts) do
    case Keyword.get(opts, :lock_version) do
      nil -> attrs
      value -> Map.put(attrs, "lock_version", value)
    end
  end

  # Sin editor de pasos en el form (`nil`) no se toca el array: el checklist que
  # viaja es el JSON del editor y el changeset lo normaliza.
  defp maybe_set_checklist(task, nil, _lock), do: {:ok, task}

  defp maybe_set_checklist(task, items, lock),
    do: set_checklist(task, items, lock_version: lock)

  # El contenido de una task es SÓLO esto: el goal es de `move_task/2` (por el
  # contenedor), el estado también, y los pasos tienen su puerta. El CUERPO sí es
  # contenido (el editor markdown del modal lo manda como `task[body]`). Un select
  # vacío llega como `""` y el changeset lo rechazaría (`validate_inclusion`):
  # se normaliza a `nil` acá, en UN lugar, para las dos superficies.
  @content_fields ~w(title body priority due_date)

  defp content_attrs(attrs) when is_map(attrs) do
    attrs
    |> Map.take(@content_fields)
    |> Map.new(fn {field, value} -> {field, normalize_blank(value)} end)
  end

  defp content_attrs(_attrs), do: %{}

  defp normalize_blank(value) when value in [nil, ""], do: nil

  defp normalize_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_blank(value), do: value

  # El lock viaja como string en un form (o ya como entero desde un caller).
  defp normalize_lock(nil), do: nil
  defp normalize_lock(""), do: nil
  defp normalize_lock(value) when is_binary(value), do: String.to_integer(value)
  defp normalize_lock(value) when is_integer(value), do: value

  # Un estado fuera del vocabulario se rechaza ANTES de escribir: un select
  # forjado no deja el contenido a medio guardar.
  defp validate_status(nil), do: :ok

  defp validate_status(status) when is_binary(status) do
    if status in Task.statuses(), do: :ok, else: {:error, :invalid_status}
  end

  defp validate_status(_status), do: {:error, :invalid_status}

  # Igual el contenido: se valida sin escribir, para que un título vacío no deje
  # los pasos ya guardados y el resto no.
  defp validate_content(_task, attrs) when attrs == %{}, do: :ok

  defp validate_content(%Task{} = task, attrs) do
    changeset = task |> Task.update_changeset(attrs) |> Map.put(:action, :validate)

    if changeset.valid?, do: :ok, else: {:error, changeset}
  end

  # Un estado ausente o igual al actual no mueve nada: mover una task que ya está
  # en esa columna reescribiría su posición sin motivo.
  defp maybe_move_status(%Task{} = task, nil), do: {:ok, task}
  defp maybe_move_status(%Task{status: status} = task, status), do: {:ok, task}

  defp maybe_move_status(%Task{} = task, status) when is_binary(status),
    do: move_task(task, %{"status" => status})

  defp normalize_lock_result({:ok, task}), do: {:ok, task}

  defp normalize_lock_result({:error, %Ecto.Changeset{errors: errors} = changeset}) do
    if Keyword.has_key?(errors, :lock_version), do: {:error, :stale}, else: {:error, changeset}
  end

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp valid_uuid?(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> true
      :error -> false
    end
  end
end
