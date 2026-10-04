defmodule Dran.Plans do
  @moduledoc """
  El contexto de planes — CRUD, checklist y el bloqueo del RMW.

  Un plan es una ENTIDAD con `owner_user_id` + `visibility` propios (default
  `private`), como un goal: no es un tipo de página y no vive en
  `knowledge_pages`. Las lecturas con `scope:` pasan por
  `Dran.ContentVisibility.filter/3` (Constraint 1); las escrituras reciben el
  dueño YA resuelto server-side (Constraint 3).

  ## El checklist es un RMW

  Tachar, agregar o reordenar pasos reescribe el array jsonb completo, así que
  `set_checklist/3` y `toggle_checklist/3` pasan por
  `Plan.checklist_changeset/2`, que aplica `optimistic_lock(:lock_version)`:
  dos manos escribiendo a la vez reciben `{:error, :stale}` en vez de pisarse.
  El changeset general (`update_plan/2`) no toca `lock_version`, igual que la
  task.
  """

  import Ecto.Query, warn: false

  alias Dran.Plans.Plan
  alias Dran.Repo

  # ──────────────────────────────────────────────────────────────────────────
  # Lectura
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Lista planes con scope de lectura.

  Opts: `:scope` (default `:all` para callers internos), `:owner_user_id`,
  `:status`, `:order` (vocabulario de `Dran.ListOrder`, default `:updated`),
  `:archived`, `:limit`.
  """
  def list_plans(opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)
    owner_user_id = Keyword.get(opts, :owner_user_id)
    status = Keyword.get(opts, :status)
    order = Keyword.get(opts, :order, :updated)
    archived = Keyword.get(opts, :archived, false)
    limit = Keyword.get(opts, :limit, 200)

    query =
      from(p in Plan,
        where: p.archived == ^archived,
        order_by: ^Dran.ListOrder.clause(order),
        limit: ^limit
      )

    query =
      if is_integer(owner_user_id),
        do: where(query, [p], p.owner_user_id == ^owner_user_id),
        else: query

    query = if status, do: where(query, [p], p.status == ^status), else: query

    query
    |> Dran.ContentVisibility.filter(scope, :plan)
    |> Repo.all()
  end

  @doc """
  Conteo de planes legibles agrupado por estado — UNA query agregada.

  Mismo papel que `Dran.Goals.status_counts/1`: el estado personal del home
  cuenta sin traer filas, y los estados no son cinco queries sino una.
  Opts: `:scope`, `:archived`, `:owner_user_id`.
  """
  def status_counts(opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)
    archived = Keyword.get(opts, :archived, false)
    owner_user_id = Keyword.get(opts, :owner_user_id)

    query =
      from(p in Plan,
        where: p.archived == ^archived,
        group_by: p.status,
        select: {p.status, count(p.id)}
      )

    query =
      if is_integer(owner_user_id),
        do: where(query, [p], p.owner_user_id == ^owner_user_id),
        else: query

    query
    |> Dran.ContentVisibility.filter(scope, :plan)
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Trae un plan por id con scope de lectura.

  Un plan fuera del scope del lector se lee como inexistente (sin fuga de
  existencia). Un id forjado no-UUID devuelve `nil` (el `Repo` reventaría con
  `Ecto.Query.CastError`).
  """
  def get_plan(id, opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)

    with true <- valid_uuid?(id) do
      Plan
      |> where([p], p.id == ^id)
      |> Dran.ContentVisibility.filter(scope, :plan)
      |> Repo.one()
    else
      _ -> nil
    end
  end

  @doc """
  Trae un plan por slug dentro del namespace de su dueño (sin scope).

  La variante con `scope:` (misma aridad, opts lista) filtra por la política
  única: el uuid es la dirección canónica y el slug el atajo legible
  (Constraint 11). Un slug de un plan ajeno privado NO se resuelve (sin fuga de
  existencia); varios dueños pueden compartir un slug, así que se toma el
  primero legible.
  """
  def get_plan_by_slug(slug, owner_user_id)
      when is_binary(slug) and is_integer(owner_user_id) do
    Repo.one(from p in Plan, where: p.slug == ^slug and p.owner_user_id == ^owner_user_id)
  end

  def get_plan_by_slug(slug, opts) when is_binary(slug) and is_list(opts) do
    scope = Keyword.get(opts, :scope, :all)

    Plan
    |> where([p], p.slug == ^slug)
    |> order_by([p], asc: p.inserted_at)
    |> Dran.ContentVisibility.filter(scope, :plan)
    |> Repo.all()
    |> List.first()
  end

  @doc "Changeset para formularios."
  def change_plan(%Plan{} = plan, attrs \\ %{}), do: Plan.changeset(plan, attrs)

  @doc """
  Progreso DERIVADO del checklist (done/total), nunca guardado.

  Un plan sin pasos reporta `0/0`: el progreso de un plan es la lectura de sus
  pasos, igual que el de un goal es la lectura de sus tasks.
  """
  def progress(%Plan{} = plan), do: progress(plan.checklist)

  def progress(items) when is_list(items) do
    total = length(items)
    done = Enum.count(items, &Dran.Checklist.done?/1)
    %{done: done, total: total, percent: if(total == 0, do: 0, else: round(done * 100 / total))}
  end

  def progress(_), do: %{done: 0, total: 0, percent: 0}

  # ──────────────────────────────────────────────────────────────────────────
  # Escritura
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Crea un plan. El slug se administra solo (deriva del título) y es único por
  dueño. `owner_user_id` llega resuelto server-side (Constraint 3).
  """
  def create_plan(attrs) do
    attrs
    |> Dran.Slug.inject_create(
      field: "title",
      fallback: "plan",
      taken?: fn candidate -> slug_taken?(attrs, candidate) end
    )
    |> then(&(%Plan{} |> Plan.changeset(&1) |> Repo.insert()))
    |> tap(fn _ -> Dran.GraphCache.invalidate_all() end)
  end

  @doc "Actualiza un plan (slug auto-administrado cuando cambia el título)."
  def update_plan(%Plan{} = plan, attrs) do
    plan
    |> Plan.changeset(
      attrs
      |> Dran.Slug.inject_update(plan,
        field: "title",
        fallback: "plan",
        lookup: &get_plan_by_slug(&1, plan.owner_user_id)
      )
    )
    |> Repo.update()
    |> tap(fn _ -> Dran.GraphCache.invalidate_all() end)
  end

  @doc """
  Borra un plan y sus aristas — `relations` es polimórfica y no tiene FK
  (Constraint 12): sin esto el grafo queda con un nodo muerto.
  """
  def delete_plan(%Plan{} = plan) do
    result =
      Repo.transaction(fn ->
        Dran.Relation.delete_edges("plan", plan.id)
        Repo.delete!(plan)
      end)

    Dran.GraphCache.invalidate_all()
    result
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Checklist — el RMW con bloqueo optimista
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Reescribe el checklist completo (array ordenado, forma canónica).

  Cualquier entrada se normaliza (`Dran.Checklist.cast/1`). Con
  `lock_version:` se exige esa versión: si el plan avanzó, devuelve
  `{:error, :stale}` en vez de pisar el trabajo de otra mano.
  """
  def set_checklist(%Plan{} = plan, items, opts \\ []) do
    attrs = %{"checklist" => items}

    attrs
    |> maybe_put_lock(opts)
    |> then(&Plan.checklist_changeset(plan, &1))
    |> Repo.update(stale_error_field: :lock_version)
    |> normalize_lock_result()
  end

  @doc """
  Tacha o destacha UN ítem del checklist, por índice (0-based) o por texto.

  La posición se busca sobre el array ACTUAL del plan (lectura-modificación-
  escritura en el contexto, no en el controlador) y la escritura respeta
  `lock_version`. Un ítem que no existe devuelve `{:error, :not_found}`.
  """
  def toggle_checklist(%Plan{} = plan, ref, opts \\ []) do
    case Dran.Checklist.toggle(plan.checklist, ref) do
      {:ok, items} -> set_checklist(plan, items, opts)
      :error -> {:error, :not_found}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Internals
  # ──────────────────────────────────────────────────────────────────────────

  defp maybe_put_lock(attrs, opts) do
    case Keyword.get(opts, :lock_version) do
      nil -> attrs
      value -> Map.put(attrs, "lock_version", value)
    end
  end

  defp normalize_lock_result({:ok, plan}), do: {:ok, plan}

  defp normalize_lock_result({:error, %Ecto.Changeset{errors: errors} = changeset}) do
    if Keyword.has_key?(errors, :lock_version), do: {:error, :stale}, else: {:error, changeset}
  end

  # El predicado `taken?` resuelve sobre el MISMO balde que el índice único
  # (`COALESCE(owner_user_id, 0)`): dos dueños pueden sostener el mismo slug y
  # el contenido de sistema comparte un solo balde, sin depender de que el
  # dueño esté presente.
  defp slug_taken?(attrs, candidate) do
    bucket = Dran.Slug.fetch_attr(attrs, "owner_user_id") || 0

    Repo.exists?(
      from p in Plan,
        where: coalesce(p.owner_user_id, 0) == ^bucket and p.slug == ^candidate
    )
  end

  defp valid_uuid?(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> true
      :error -> false
    end
  end
end
