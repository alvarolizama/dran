defmodule Dran.Skills.BuiltinBoot do
  @moduledoc """
  El boot de los skills de SISTEMA: reconcilia la tabla `skills` con los
  `SKILL.md` que ship el código, después del Repo y en cada arranque.

  Es el mismo molde que `Dran.SystemActorsBoot` (una Task `:temporary` en el
  árbol de supervisión): los built-ins son contenido de CÓDIGO, así que su
  sincronización no es un trabajo de datos que alguien tenga que correr a mano
  — es parte de levantar la aplicación. Idempotente: en un arranque sin cambios
  no escribe una sola fila.

  En `test` el sync está APAGADO (`config :dran, :builtin_skills_autosync`): la
  suite es determinista y los tests que los necesitan los sincronizan ellos
  mismos, dentro de su transacción del sandbox. Precedente: `Dran.Scheduler` con
  `jobs: []`.

  Un fallo del sync NO tumba el arranque (la app sirve lo que haya en la tabla),
  pero queda en el log con el motivo: silenciarlo convertiría una migración sin
  correr en un catálogo vacío sin explicación.
  """

  require Logger

  @doc "El child spec del árbol de supervisión, o `nil` cuando el sync está apagado."
  def child_spec do
    if enabled?() do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [[]]},
        restart: :temporary
      }
    end
  end

  @doc "¿Corre el sync al arrancar? (`config :dran, :builtin_skills_autosync`)"
  def enabled?, do: Application.get_env(:dran, :builtin_skills_autosync, true)

  @doc false
  def start_link(_opts), do: Task.start_link(&sync/0)

  @doc "Sincroniza y reporta el resumen en el log."
  def sync do
    summary = Dran.Skills.Builtin.sync!()

    Logger.info(
      "built-in skills: #{summary.total} served " <>
        "(#{summary.created} created, #{summary.updated} updated, #{summary.pruned} pruned)"
    )

    :ok
  rescue
    error ->
      Logger.error(
        "built-in skills: sync failed — #{Exception.message(error)}. " <>
          "The catalog serves what the table already has; fix the cause and restart."
      )

      :error
  end
end
