defmodule Dran.Skills.Builtin do
  @moduledoc """
  Los skills de SISTEMA: las instrucciones que Dran sirve por DEFAULT a toda
  credencial que consume su API (cuenta, grupo o admin legacy), sin share y sin
  que nadie tenga que darlos de alta.

  ## La fuente es la carpeta de skills del PLUGIN

  El contenido son los `SKILL.md` de `hermes_plugin/dran/skills/<slug>/SKILL.md`:
  el router (`loader`) y los ocho flows (`knowledge-flow`, `relations-flow`,
  `workers-flow`, `memory-flow`, `goal-flow`, `plan-flow`, `services-flow`,
  `skills-flow`).

  Viven CON el plugin porque documentan su superficie de tools — el router no
  puede quedar describiendo una versión vieja del cliente — y son, además, las
  filas locales que el plugin registra (`dran:<slug>`): el MISMO archivo se sirve
  por las dos puertas (el catálogo remoto y `skills_list`), así que ninguna puede
  divergir de la otra.

  Se leen al **compilar** (`@external_resource` por archivo y por directorio, así
  que tocar un flow —o agregar uno nuevo— recompila este módulo) y quedan
  horneados en el beam: en runtime el directorio no hace falta, el release sirve
  exactamente lo que se compiló, y no hay un segundo lugar donde el contenido
  pueda divergir.

  Corolario: cambiar un built-in es editar el archivo y hacer redeploy. No se
  escriben por API ni por la web (`system: true` es server-side y su slug está
  reservado).

  ## El contrato se valida al COMPILAR

  El parseo y las validaciones viven en `Dran.Skills.Builtin.Parser` (un módulo
  aparte, porque un módulo no puede llamarse a sí mismo mientras se define): un
  archivo que no cumple el wire aborta la compilación con su ruta y el motivo.
  """

  @skills_dir Path.expand("../../../hermes_plugin/dran/skills", __DIR__)
  @wildcard "*/SKILL.md"

  files = @skills_dir |> Path.join(@wildcard) |> Path.wildcard() |> Enum.sort()

  if files == [] do
    raise """
    built-in skills not found: no SKILL.md matched #{@skills_dir}/#{@wildcard}

    The source of the system skills is `hermes_plugin/dran/skills/<slug>/SKILL.md`
    (the router plus the eight flows). If you are building from a different
    directory (an image without them), copy that directory into the build context
    — the content is read at COMPILE time and served from the beam afterwards.
    Serving an empty catalog in silence is worse than failing the build.
    """
  end

  for file <- files do
    @external_resource file
  end

  # El directorio también: un skill NUEVO tiene que recompilar el catálogo.
  @external_resource @skills_dir

  @definitions Enum.map(files, &Dran.Skills.Builtin.Parser.parse!/1)
  @slugs Enum.map(@definitions, & &1.slug)

  @doc """
  Las definiciones embebidas: `[%{slug, name, description, body, file}]`, en
  orden de archivo.
  """
  def all, do: @definitions

  @doc "Los slugs servidos por default (el conjunto que se reconcilia en cada boot)."
  def slugs, do: @slugs

  @doc "El directorio del que se leyeron los archivos (para reportes y tests)."
  def skills_dir, do: @skills_dir

  @doc """
  Reconcilia la tabla `skills` con las definiciones embebidas.

  Idempotente: sin cambios no escribe nada, un cuerpo distinto bumpea la versión
  y un built-in que ya no se sirve se poda. Devuelve el resumen del sync.
  """
  def sync!, do: Dran.Skills.sync_system_skills(@definitions)
end
