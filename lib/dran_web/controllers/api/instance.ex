defmodule DranWeb.API.Instance do
  @moduledoc """
  Shared helpers for the REST surface in the single-workspace model
  (W5, contract-instance-visibility-20260919).

  The instance IS the workspace: every endpoint resolves its context through
  `instance_context/0` and ignores legacy `workspace` params (accepted for
  backward compatibility, never trusted to pick another container).

  Read scopes come from `Dran.ContentVisibility` — never a local rule.
  """

  @doc """
  The one context every API call operates on. Returns nil only on an
  un-migrated/empty instance (callers fail closed with 404/422).

  W7 (contract auditoria-fixes): la fila se resuelve UNA vez por request —
  `require_api_token` la guarda en el proceso — y las demás llamadas del
  request la LEEN. Antes cada call-site re-queryaba la fila (medido: 5× en un
  GET del API).
  """
  def instance_context do
    case Process.get(:dran_instance_workspace, :miss) do
      %Dran.Workspace{} = ws -> ws
      nil -> nil
      :miss -> Dran.Auth.instance_workspace()
    end
  end

  @doc """
  W7: el punto que RESUELVE y cachea la instancia para el request (llamado por
  `require_api_token`). El valor vive en el proceso, no en ETS: no hay estado
  entre requests que invalidar.
  """
  def cache_instance_for_request do
    ws = Dran.Auth.instance_workspace()
    Process.put(:dran_instance_workspace, ws)
    :ok
  end

  @doc """
  The context id for write paths (fail-closed: nil when there is no
  instance workspace — the caller must reject the write).
  """
  def instance_context_id do
    case instance_context() do
      %{id: id} -> id
      nil -> nil
    end
  end

  @doc """
  Legacy-param tolerant context resolution: whatever `workspace` value the
  request carries (slug, uuid, garbage), the answer is the instance
  workspace. The param stopped meaning anything in W1.
  """
  def resolve_context(_legacy_param), do: instance_context()

  @doc "The read scope for `conn` (single policy module)."
  def scope_for(conn, kind) do
    Dran.ContentVisibility.resolve(instance_context(), conn.assigns[:user], kind)
  end

  @doc """
  Permitted write fields for pages: `visibility` is client-settable on
  create/update (contract Rules#5) — memories reject it (Rules#6, 422).
  """
  @page_write_fields ~w(title slug body page_type summary tags meta kb_confidence kb_source_url visibility archived pinned)
  def page_write_fields, do: @page_write_fields

  # ── El contenedor de trabajo y el plan (W2, contrato de superficies) ──────
  #
  # Whitelist, no blacklist (SEC-006): el cliente no manda `owner_user_id` ni
  # `visibility` — el dueño sale de la credencial (Constraint 3) y el destino de
  # la `scope` (Constraint 5). En las tasks, `status`/`position`/`goal_id`/
  # `lock_version` NO son campos de escritura directa: la columna y el goal se
  # cambian SÓLO por `move_task/2` (Constraint 13).

  @goal_write_fields ~w(title slug summary body horizon starts_on due_on status progress_manual pinned archived)
  @task_write_fields ~w(title slug body priority due_date assignee_id checklist recurrence completed_at archived)
  @plan_write_fields ~w(title slug summary body status starts_on due_on archived)
  # Skills: el contrato de wire es la superficie de escritura. `owner_user_id`
  # NO está (el dueño sale de la credencial) y `version`/`content_hash` tampoco:
  # los administra el changeset y el contexto, nunca el cliente.
  @skill_write_fields ~w(slug name description body visibility)

  def goal_write_fields, do: @goal_write_fields
  def task_write_fields, do: @task_write_fields
  def plan_write_fields, do: @plan_write_fields
  def skill_write_fields, do: @skill_write_fields

  @doc "Strips client params to the goal write fields."
  def permit_goal_params(params), do: Map.take(params, @goal_write_fields)

  @doc "Strips client params to the task write fields (see the note above)."
  def permit_task_params(params), do: Map.take(params, @task_write_fields)

  @doc "Strips client params to the plan write fields (`checklist` has its own door)."
  def permit_plan_params(params), do: Map.take(params, @plan_write_fields)

  @doc "Strips client params to the skill write fields (owner and version are server-side)."
  def permit_skill_params(params), do: Map.take(params, @skill_write_fields)

  @doc """
  Resolves an id-or-slug route segment (Constraint 11).

  A uuid is canonical and the slug is a readable fallback. The 36-byte guard
  runs BEFORE the cast: `Ecto.UUID.cast/1` accepts a raw 16-byte binary, so a
  16-char slug would be read as a uuid and the lookup would miss. Both lookups
  receive the already-validated segment (the caller closes the read scope).
  """
  def fetch_segment(segment, by_id, by_slug) when is_binary(segment) do
    if byte_size(segment) == 36 do
      case Ecto.UUID.cast(segment) do
        {:ok, uuid} -> by_id.(uuid)
        :error -> by_slug.(segment)
      end
    else
      by_slug.(segment)
    end
  end

  def fetch_segment(_segment, _by_id, _by_slug), do: nil

  @doc """
  La identidad de escritura resuelta server-side: el dueño de la credencial.

  Devuelve `%{"owner_user_id" => id}` o `%{}` cuando la credencial no tiene
  dueño (el token admin legacy): ahí el caller decide, nunca el body.
  """
  def owner_attrs(conn) do
    case Dran.Auth.resolve_owner_user_id(conn.assigns[:user]) do
      nil -> %{}
      user_id -> %{"owner_user_id" => user_id}
    end
  end

  @doc """
  Strips client params down to the permitted write fields, dropping
  server-owned ones (workspace_id, owner, created_by…).
  """
  def permit_page_params(params) do
    Map.take(params, @page_write_fields)
  end

  @doc """
  Extrae el destino de escritura (`scope`) de los params del cliente (W6).

  Devuelve `{scoped?, scope, params}`:

    * `scoped?` distingue "sin `scope`" (la escritura conserva el default /
      el `visibility` legacy de páginas) de un `scope` explícito, que gobierna.
    * `scope` es el valor crudo (`"private"` | `"public"` | `%{"group" => slug}`).
    * `params` ya sin el campo, para que no viaje a los attrs del recurso.

  Con `drop_visibility: true` (páginas) también quita el `visibility` legacy
  cuando hay `scope`, para que el destino declarado no se contradiga.
  """
  def pop_write_scope(params, opts \\ []) do
    if Map.has_key?(params, "scope") do
      scope = params["scope"]

      params =
        params
        |> Map.delete("scope")
        |> then(fn p -> if opts[:drop_visibility], do: Map.delete(p, "visibility"), else: p end)

      {true, scope, params}
    else
      {false, nil, params}
    end
  end

  @doc """
  El destino de escritura de ESTA petición, con la CREDENCIAL mandando (W2,
  contract grupo-credencial).

  Es `pop_write_scope/2` más la regla de una credencial ATADA a un destino (hoy:
  el token de un grupo): esa credencial escribe SÓLO ahí, así que sin `scope` el
  destino ES el suyo — y con un `scope` explícito se deja pasar tal cual para
  que la frontera (`Dran.Sharing.apply_scope/4`) lo acepte o lo rechace con 422.
  La comparación vive en UN punto y ningún controlador conoce el destino de la
  credencial: acá viaja como un término opaco que se fuerza.

  El token de cuenta no trae atadura y se comporta exactamente como
  `pop_write_scope/2` (Constraints 4 y 6).
  """
  def write_scope(conn, params, opts \\ []) do
    {scoped?, scope, params} = pop_write_scope(params, opts)

    case bound_write_scope(conn) do
      nil -> {scoped?, scope, params}
      forced -> if scoped?, do: {true, scope, params}, else: {true, forced, params}
    end
  end

  # El destino que la credencial impone, si impone alguno. Sólo la identidad de
  # grupo lo trae (lo arma el punto de autenticación).
  defp bound_write_scope(conn) do
    case conn.assigns[:user] do
      %{} = identity -> Map.get(identity, :write_scope)
      _ -> nil
    end
  end
end
