defmodule Dran.Goals do
  @moduledoc """
  El contexto de goals — CRUD, jerarquía y el **goal bandeja**.

  Un goal es el contenedor de trabajo: sus tasks cuelgan con `goal_id NOT
  NULL` (invariante del motor) y su progreso se DERIVA de ellas (done/total),
  nunca se guarda. `progress_manual` cubre el goal sin tasks.

  ## Lectura

  Las lecturas con `scope:` pasan por `Dran.ContentVisibility.filter/3`; las
  escrituras reciben `owner_user_id` YA resuelto server-side (nunca del body).

  ## El goal bandeja

  `ensure_inbox/1` crea perezosamente, por dueño, el goal donde cae la captura
  rápida. Es la única puerta que hace sostenible el `NOT NULL` en la práctica
  (Constraint 11): sin él, "una task no existe sin goal" sería un chequeo de
  app que el flujo de captura podría saltar.
  """

  import Ecto.Query, warn: false

  alias Dran.Repo
  alias Dran.Goals.Goal
  alias Dran.Tasks.Task

  @inbox_slug "inbox"

  # ──────────────────────────────────────────────────────────────────────────
  # Lectura
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Lista goals con scope de lectura.

  Opts: `:scope` (default `:all` para callers internos), `:owner_user_id`,
  `:status`, `:order` (vocabulario de `Dran.ListOrder`, default `:title`),
  `:archived`, `:limit`.
  """
  def list_goals(opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)
    owner_user_id = Keyword.get(opts, :owner_user_id)
    status = Keyword.get(opts, :status)
    order = Keyword.get(opts, :order, :title)
    archived = Keyword.get(opts, :archived, false)
    limit = Keyword.get(opts, :limit, 200)

    query =
      from(g in Goal,
        where: g.archived == ^archived,
        order_by: ^Dran.ListOrder.clause(order),
        limit: ^limit
      )

    query =
      if is_integer(owner_user_id),
        do: where(query, [g], g.owner_user_id == ^owner_user_id),
        else: query

    query = if status, do: where(query, [g], g.status == ^status), else: query

    query
    |> Dran.ContentVisibility.filter(scope, :goal)
    |> Repo.all()
  end

  @doc """
  Trae un goal por id con scope de lectura.

  Un goal fuera del scope del lector se lee como inexistente (sin fuga de
  existencia). Un id forjado no-UUID devuelve `nil` (el `Repo` reventaría con
  `Ecto.Query.CastError`).
  """
  def get_goal(id, opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)

    with true <- valid_uuid?(id) do
      Goal
      |> where([g], g.id == ^id)
      |> Dran.ContentVisibility.filter(scope, :goal)
      |> Repo.one()
    else
      _ -> nil
    end
  end

  @doc "Trae un goal por slug dentro del namespace de su dueño (sin scope). La variante con `scope:` (aridad 2, opts lista) filtra por la política única."
  def get_goal_by_slug(slug, owner_user_id)
      when is_binary(slug) and is_integer(owner_user_id) do
    Repo.one(from g in Goal, where: g.slug == ^slug and g.owner_user_id == ^owner_user_id)
  end

  # Variante con `scope:` — el uuid es la dirección canónica y el slug atajo
  # legible (Constraint 14). El filtro sale de la política única: un slug de un
  # goal ajeno privado NO se resuelve (sin fuga de existencia). Varios dueños
  # pueden compartir un slug, así que se toma el primero legible.
  def get_goal_by_slug(slug, opts) when is_binary(slug) and is_list(opts) do
    scope = Keyword.get(opts, :scope, :all)

    Goal
    |> where([g], g.slug == ^slug)
    |> order_by([g], asc: g.inserted_at)
    |> Dran.ContentVisibility.filter(scope, :goal)
    |> Repo.all()
    |> List.first()
  end

  @doc "Children directos de un goal."
  def list_children(%Goal{} = goal), do: list_children(goal.id)

  def list_children(goal_id) when is_binary(goal_id) do
    Repo.all(from g in Goal, where: g.parent_goal_id == ^goal_id, order_by: [asc: g.title])
  end

  @doc """
  Children directos de un goal, con scope de lectura.

  Un hijo ajeno privado no se lista: la jerarquía no abre una segunda puerta a
  contenido que el lector no puede leer (misma política única que `list_goals/1`).
  """
  def list_children(%Goal{} = goal, opts), do: list_children(goal.id, opts)

  def list_children(goal_id, opts) when is_binary(goal_id) and is_list(opts) do
    scope = Keyword.get(opts, :scope, :all)

    Goal
    |> where([g], g.parent_goal_id == ^goal_id)
    |> order_by([g], asc: g.title)
    |> Dran.ContentVisibility.filter(scope, :goal)
    |> Repo.all()
  end

  @doc "Changeset para formularios."
  def change_goal(%Goal{} = goal, attrs \\ %{}), do: Goal.changeset(goal, attrs)

  # ──────────────────────────────────────────────────────────────────────────
  # Escritura
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Crea un goal. El slug se administra solo (deriva del título) y es único por
  dueño. `owner_user_id` llega resuelto server-side.
  """
  def create_goal(attrs) do
    attrs
    |> Dran.Slug.inject_create(
      field: "title",
      fallback: "goal",
      taken?: fn candidate -> slug_taken?(attrs, candidate) end
    )
    |> then(&(%Goal{} |> Goal.changeset(&1) |> Repo.insert()))
  end

  @doc "Actualiza un goal (slug auto-administrado cuando cambia el título)."
  def update_goal(%Goal{} = goal, attrs) do
    attrs
    |> Dran.Slug.inject_update(goal,
      field: "title",
      fallback: "goal",
      lookup: &get_goal_by_slug(&1, goal.owner_user_id)
    )
    |> then(&(goal |> Goal.changeset(&1) |> Repo.update()))
  end

  @doc """
  Borra un goal, sus tasks (por FK `delete_all`) y las aristas del goal y de
  cada task — `relations` es polimórfica y no tiene FK (Constraint 15 / F29).
  """
  def delete_goal(%Goal{} = goal) do
    task_ids =
      Repo.all(from t in Task, where: t.goal_id == ^goal.id, select: t.id)

    {:ok, deleted} =
      Repo.transaction(fn ->
        Dran.Relation.delete_edges("goal", goal.id)
        Enum.each(task_ids, &Dran.Relation.delete_edges("task", &1))
        Repo.delete!(goal)
      end)

    {:ok, deleted}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Goal bandeja (captura rápida)
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  El goal bandeja del dueño, creado perezosamente.

  Acepta el id del dueño, un `%Dran.Accounts.User{}` o una identidad de API
  (mapa con `:created_by_user_id`). Idempotente: la segunda llamada devuelve
  el mismo goal. Sin dueño resoluble devuelve `{:error, :no_owner}` — la
  bandeja es personal, no de sistema.
  """
  def ensure_inbox(owner_id) when is_integer(owner_id), do: do_ensure_inbox(owner_id)

  def ensure_inbox(owner) do
    case Dran.Auth.resolve_owner_user_id(owner) do
      nil -> {:error, :no_owner}
      owner_id -> do_ensure_inbox(owner_id)
    end
  end

  @doc "El goal bandeja del dueño, o `nil` si todavía no existe."
  def get_inbox(owner_id) when is_integer(owner_id) do
    Repo.one(
      from g in Goal,
        where: g.owner_user_id == ^owner_id and g.slug == ^@inbox_slug
    )
  end

  defp do_ensure_inbox(owner_id) do
    case get_inbox(owner_id) do
      %Goal{} = goal ->
        {:ok, goal}

      nil ->
        case create_goal(%{
               "title" => "Bandeja de entrada",
               "slug" => @inbox_slug,
               "owner_user_id" => owner_id,
               "horizon" => "day",
               "status" => "active"
             }) do
          {:ok, goal} ->
            {:ok, goal}

          {:error, changeset} ->
            # Carrera: otro proceso la creó entre el select y el insert.
            case get_inbox(owner_id) do
              %Goal{} = goal -> {:ok, goal}
              nil -> {:error, changeset}
            end
        end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Progreso DERIVADO
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Progreso derivado de las tasks del goal (done/total), nunca guardado.

  Devuelve `%{done:, total:, derived_percent:, manual:, percent:}`. Cuando
  `progress_manual` está seteado, `percent` lo usa a él (cubre el goal sin
  tasks); si no, usa el derivado.
  """
  def progress(%Goal{} = goal), do: progress(goal.id, goal.progress_manual)
  def progress(nil), do: empty_progress(nil)

  def progress(goal_id) when is_binary(goal_id), do: progress(goal_id, nil)

  def progress(goal_id, manual) when is_binary(goal_id) do
    {total, done} = task_counts([goal_id]) |> Map.get(goal_id, {0, 0})
    build_progress(total, done, manual)
  end

  @doc """
  Progreso de una LISTA de goals, en UNA consulta agregada.

  `progress/1` es correcto para el detalle y un N+1 en el índice: acá los
  conteos se agrupan por `goal_id` (el `done` sale de `FILTER (WHERE …)`) y se
  respeta el `progress_manual` de cada goal. Devuelve `%{goal_id => progreso}`
  con una entrada para CADA goal de la lista — el que no tiene tasks reporta
  `0/0`, igual que en el detalle.
  """
  def progress_map(goals) when is_list(goals) do
    counts = task_counts(Enum.map(goals, & &1.id))

    Map.new(goals, fn goal ->
      {total, done} = Map.get(counts, goal.id, {0, 0})
      {goal.id, build_progress(total, done, goal.progress_manual)}
    end)
  end

  def progress_map(_), do: %{}

  # `{goal_id => {total, done}}` de las tasks VIVAS (archived == false) de esos
  # goals. Una sola vuelta a la base, sin importar cuántos goals haya.
  defp task_counts([]), do: %{}

  defp task_counts(goal_ids) do
    Repo.all(
      from t in Task,
        where: t.goal_id in ^goal_ids and t.archived == false,
        group_by: t.goal_id,
        select: {t.goal_id, count(t.id), filter(count(t.id), t.status == "done")}
    )
    |> Map.new(fn {goal_id, total, done} -> {goal_id, {total, done}} end)
  end

  defp build_progress(total, done, manual) do
    derived = if total == 0, do: 0, else: round(done * 100 / total)

    %{
      done: done,
      total: total,
      derived_percent: derived,
      manual: manual,
      percent: manual || derived
    }
  end

  defp empty_progress(manual), do: build_progress(0, 0, manual)

  # ── Internals ─────────────────────────────────────────────────────────────

  defp slug_taken?(attrs, candidate) do
    case Dran.Slug.fetch_attr(attrs, "owner_user_id") do
      owner_id when is_integer(owner_id) -> get_goal_by_slug(candidate, owner_id) != nil
      _ -> false
    end
  end

  # Los params forjados pueden traer cualquier binario; `Repo.get/2` revienta
  # con un id no-UUID.
  defp valid_uuid?(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> true
      :error -> false
    end
  end
end
