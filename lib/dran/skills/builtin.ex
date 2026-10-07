defmodule Dran.Skills.Builtin do
  @moduledoc """
  Los skills de SISTEMA: las instrucciones que Dran sirve por DEFAULT a toda
  credencial que consume su API (cuenta, grupo o admin legacy), sin share y sin
  que nadie tenga que darlos de alta.

  ## La fuente es el repo

  El contenido son los archivos `skills/<slug>/SKILL.md` — los mismos que un
  agente Hermes instala en su disco. Se leen al **compilar** (`@external_resource`
  por archivo, así que tocar un flow recompila este módulo) y quedan horneados en
  el beam: en runtime el directorio no hace falta, el release sirve exactamente lo
  que se compiló, y no hay un segundo lugar donde el contenido pueda divergir.

  Corolario: cambiar un built-in es editar el archivo y hacer redeploy. No se
  escriben por API ni por la web (`system: true` es server-side y su slug está
  reservado).

  ## El contrato se valida al COMPILAR

  El parseo y las validaciones viven en `Dran.Skills.Builtin.Parser` (un módulo
  aparte, porque un módulo no puede llamarse a sí mismo mientras se define): un
  archivo que no cumple el wire aborta la compilación con su ruta y el motivo.
  """

  @skills_dir Path.expand("../../../skills", __DIR__)
  @wildcard Path.join(@skills_dir, "*/SKILL.md")

  files = @wildcard |> Path.wildcard() |> Enum.sort()

  if files == [] do
    raise """
    built-in skills not found: no SKILL.md matched #{@wildcard}

    The source of the system skills is the repo's `skills/<slug>/SKILL.md`. If
    you are building from a different directory (an image without the suite),
    copy `skills/` into the build context — the content is read at COMPILE time
    and served from the beam afterwards. Serving an empty catalog in silence is
    worse than failing the build.
    """
  end

  for file <- files do
    @external_resource file
  end

  @definitions Enum.map(files, &Dran.Skills.Builtin.Parser.parse!/1)
  @slugs Enum.map(@definitions, & &1.slug)

  @doc """
  Las definiciones embebidas: `[%{slug, name, description, body}]`, en orden de archivo.
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
