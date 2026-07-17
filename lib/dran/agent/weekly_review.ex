defmodule Dran.Agent.WeeklyReview do
  @moduledoc """
  Weekly Review agent: recopila estadísticas del brain y genera un
  review semanal en formato markdown como página journal.

  Tools:
    * `gather_stats` — recopila Brain.stats, goals con health/meta,
      todos agrupados por kanban_status, y páginas creadas en los
      últimos 7 días. SIN LLM.
    * `create_review_page` — crea una página note (journal) con el
      markdown del review. Meta incluye kind "journal", review "weekly"
      y la semana ISO actual (ej. "2026-W29").
    * `done` — finaliza la sesión.
  """

  @behaviour Dran.Agent.Engine.Behaviour

  import Ecto.Query

  alias Dran.{Auth, Brain, Repo}
  alias Dran.Brain.Page

  @agent_type "weekly_review"
  @recent_window_days 7

  defmodule State do
    @moduledoc false
    defstruct session: nil,
              module: nil,
              messages: [],
              step: 0,
              pages_created: 0,
              opts: [],
              stats: nil
  end

  @doc """
  Start a weekly review session.
  """
  @spec run(String.t(), Ecto.UUID.t(), keyword()) :: {:ok, Dran.Agent.Session.t()}
  def run(input, context_id, opts \\ []) do
    Dran.Agent.Engine.run(__MODULE__, input, context_id, opts)
  end

  @doc """
  Run a scheduled weekly review pass on the default context.

  Resolves the default context slug via `Auth.default_context_slug/0`,
  looks it up, and starts the engine.
  """
  @spec run_scheduled() :: {:ok, Dran.Agent.Session.t()} | {:error, :context_not_found}
  def run_scheduled do
    slug = Auth.default_context_slug()

    case Brain.get_context_by_slug(slug) do
      nil ->
        {:error, :context_not_found}

      ctx ->
        run("scheduled weekly review", ctx.id)
    end
  end

  @impl true
  def agent_type, do: @agent_type

  @doc "Window in days for recently created pages."
  def recent_window_days, do: @recent_window_days

  @impl true
  def tools do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "gather_stats",
          "description" =>
            "Recopila estadísticas del brain: Brain.stats, goals con su health/meta, " <>
              "todos agrupados por kanban_status, y páginas creadas en los últimos " <>
              "#{recent_window_days()} días. Devuelve un mapa estructurado. No usa LLM.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{},
            "required" => []
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "create_review_page",
          "description" =>
            "Crea una página note (journal) con el markdown del review semanal. " <>
              "La meta incluye kind \"journal\", review \"weekly\" y la semana ISO actual.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "body" => %{
                "type" => "string",
                "description" => "Markdown del review semanal en español"
              }
            },
            "required" => ["body"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "done",
          "description" => "Finaliza la sesión de weekly review con un resumen.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "summary" => %{
                "type" => "string",
                "description" => "Breve resumen del review generado"
              }
            },
            "required" => ["summary"]
          }
        }
      }
    ]
  end

  @impl true
  def system_prompt(_opts \\ []) do
    """
    Eres el agente Weekly Review de Dran, el segundo cerebro. Tu trabajo es
    generar un review semanal en español a partir de los datos agregados del brain.

    Workflow:
    1. Llama `gather_stats` para obtener estadísticas, goals (con health/meta),
       todos agrupados por kanban_status, y páginas nuevas de los últimos
       #{recent_window_days()} días.
    2. Con los datos agregados, redacta un markdown del review semanal con estas
       secciones en español:
       - **Goals**: lista de goals con su health (green/yellow/red) y meta relevante.
       - **Todos completados vs pendientes**: conteo por kanban_status, destacando
         los completados (done) vs pendientes.
       - **Páginas nuevas**: páginas creadas en los últimos 7 días.
       - **Sugerencias**: recomendaciones accionables para la próxima semana.
    3. Llama `create_review_page` con el markdown generado.
    4. Llama `done` con un breve resumen.

    REGLAS:
    - El review debe estar en español.
    - Sé conciso pero informativo.
    - Las sugerencias deben ser accionables y específicas.
    - Finaliza llamando `done`.
    """
  end

  def build_messages(input, session, _opts \\ []) do
    [
      %{"role" => "system", "content" => system_prompt()},
      %{"role" => "user", "content" => "Weekly review task: #{input}\nSession: #{session.id}"}
    ]
  end

  @impl true
  def init_state(session, module, opts) do
    %State{
      session: session,
      module: module,
      messages: build_messages(session.input, session, opts),
      step: 0,
      pages_created: 0,
      opts: opts,
      stats: nil
    }
  end

  # ── Tool execution ──────────────────────────────────────────────────────

  @impl true
  def execute_tool("gather_stats", _args, %State{} = state) do
    context_id = state.session.context_id

    stats = Brain.stats(context_id)

    goals =
      Repo.all(
        from p in Page,
          where: p.context_id == ^context_id and p.page_type == "goal",
          order_by: [asc: p.title],
          select: %{
            slug: p.slug,
            title: p.title,
            health: fragment("?->>'health'", p.meta),
            target_date: fragment("?->>'target_date'", p.meta),
            start_date: fragment("?->>'start_date'", p.meta),
            team: fragment("?->>'team'", p.meta),
            meta: p.meta
          }
      )

    todos =
      Repo.all(
        from p in Page,
          where: p.context_id == ^context_id and p.page_type == "todo",
          order_by: [asc: p.title],
          select: %{
            slug: p.slug,
            title: p.title,
            kanban_status: fragment("?->>'kanban_status'", p.meta),
            priority: fragment("?->>'priority'", p.meta),
            goal_slug: fragment("?->>'goal_slug'", p.meta)
          }
      )

    todos_by_status =
      todos
      |> Enum.group_by(fn t -> t.kanban_status || "backlog" end)
      |> Enum.map(fn {status, list} -> {status, length(list)} end)
      |> Map.new()

    cutoff = DateTime.utc_now() |> DateTime.add(-@recent_window_days * 24 * 3600, :second)

    recent_pages =
      Repo.all(
        from p in Page,
          where: p.context_id == ^context_id and p.inserted_at >= ^cutoff,
          order_by: [desc: p.inserted_at],
          limit: 50,
          select: %{
            slug: p.slug,
            title: p.title,
            page_type: p.page_type,
            inserted_at: p.inserted_at
          }
      )

    result = %{
      stats: stats,
      goals: goals,
      todos: todos,
      todos_by_status: todos_by_status,
      recent_pages: recent_pages,
      week: current_iso_week()
    }

    {{:ok, result}, %{state | stats: result}}
  end

  def execute_tool("create_review_page", args, %State{} = state) do
    body = args["body"] || ""

    if String.trim(body) == "" do
      {{:error, "body is required"}, state}
    else
      week = current_iso_week()
      date = Date.utc_today() |> Date.to_iso8601()
      title = "Weekly Review #{week}"

      page_attrs = %{
        context_id: state.session.context_id,
        title: title,
        body: body,
        page_type: "note",
        created_by: "weekly-review",
        owner: "weekly-review",
        meta: %{
          "kind" => "journal",
          "review" => "weekly",
          "week" => week,
          "date" => date,
          "agent_session_id" => state.session.id
        }
      }

      case Brain.create_page(page_attrs) do
        {:ok, page} ->
          Phoenix.PubSub.broadcast(
            Dran.PubSub,
            "agents:#{state.session.id}",
            {:page_created, page}
          )

          {{:ok, %{slug: page.slug, id: page.id, title: page.title}},
           %{state | pages_created: state.pages_created + 1}}

        {:error, cs} ->
          {{:error, format_changeset_errors(cs)}, state}
      end
    end
  end

  def execute_tool("done", _args, %State{} = state), do: {{:ok, :done}, state}

  def execute_tool(_tool, _args, %State{} = state), do: {{:error, :unknown_tool}, state}

  # ── Behaviour callbacks (optional) ──────────────────────────────────────

  @impl true
  def summarize_result({:ok, :done}), do: %{status: "done"}

  def summarize_result({:ok, %{slug: slug, title: title}}) do
    %{status: "ok", slug: slug, title: title}
  end

  def summarize_result({:ok, result}) when is_map(result) do
    %{status: "ok", data: result}
  end

  def summarize_result({:error, reason}) when is_binary(reason) do
    %{status: "error", error: reason}
  end

  def summarize_result({:error, reason}), do: %{status: "error", error: inspect(reason)}

  @impl true
  def gathered_summary(%State{stats: nil}) do
    "Llama `gather_stats` para recopilar datos, luego `create_review_page` con el markdown " <>
      "del review semanal y finalmente `done`."
  end

  def gathered_summary(%State{stats: stats}) do
    goals_count = length(stats.goals)
    todos_count = length(stats.todos)
    recent_count = length(stats.recent_pages)

    "Stats recopiladas: #{goals_count} goal(s), #{todos_count} todo(s), " <>
      "#{recent_count} página(s) nuevas (#{stats.week}). " <>
      "Redacta el markdown del review y llama `create_review_page`, luego `done`."
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  @doc """
  Returns the current ISO week as a string like "2026-W29".
  """
  def current_iso_week do
    today = Date.utc_today()
    year = today.year

    # ISO weekday: Monday=1..Sunday=7
    iso_weekday = Date.day_of_week(today, :monday)

    # Day of year
    jan1 = Date.new!(year, 1, 1)
    day_of_year = Date.diff(today, jan1) + 1

    # ISO week: ((day_of_year - iso_weekday) + 10) / 7
    # If the result is 0, the week belongs to the previous year.
    # If the result is 53 and the year has 52 weeks, it belongs to the next year.
    week = div(day_of_year - iso_weekday + 10, 7)

    {year, week} =
      cond do
        week == 0 ->
          # Belongs to the last week of the previous year
          {year - 1, iso_weeks_in_year(year - 1)}

        week == 53 and not iso_year_has_53_weeks?(year) ->
          {year + 1, 1}

        true ->
          {year, week}
      end

    "#{year}-W#{String.pad_leading(Integer.to_string(week), 2, "0")}"
  end

  # A year has 53 ISO weeks if its first day is Thursday, or if it's a leap
  # year and January 1 is Wednesday.
  defp iso_year_has_53_weeks?(year) do
    jan1 = Date.new!(year, 1, 1)
    weekday = Date.day_of_week(jan1, :monday)

    cond do
      weekday == 4 -> true
      weekday == 3 and Date.leap_year?(jan1) -> true
      true -> false
    end
  end

  defp iso_weeks_in_year(year) do
    if iso_year_has_53_weeks?(year), do: 53, else: 52
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, val}, acc ->
        String.replace(acc, "%{#{key}}", to_string(val))
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end
end
