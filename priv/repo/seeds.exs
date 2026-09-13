# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Creates the default context and seeds it with realistic Spanish content:
# notes with embeds, concepts with semantic relations.
# Idempotent — safe to run multiple times.
#
# Admin users are NOT created here: the first-run /setup web flow handles
# initial admin creation.

import Ecto.Query
alias Dran.Repo
alias Dran.Knowledge
alias Dran.Workspace

# ──────────────────────────────────────────────────────────────────────────
# Seeds only run when the default context is explicitly configured via
# DRAN_WORKSPACE_SLUG / DRAN_WORKSPACE_NAME — otherwise a deleted "personal"
# context would keep coming back from the dead.
# ──────────────────────────────────────────────────────────────────────────

unless Dran.Auth.default_context_configured?() do
  IO.puts("DRAN_WORKSPACE_SLUG/DRAN_WORKSPACE_NAME not set — skipping seeds.")
  exit(:normal)
end

# ──────────────────────────────────────────────────────────────────────────
# Ensure the default context exists
# ──────────────────────────────────────────────────────────────────────────

workspace_slug = Dran.Auth.default_workspace_slug()
context_name = Dran.Auth.default_workspace_name()

context =
  case Repo.get_by(Workspace, slug: workspace_slug) do
    nil ->
      {:ok, ctx} = Knowledge.create_workspace(%{name: context_name, slug: workspace_slug})
      IO.puts("Created context: #{ctx.name} (#{ctx.slug})")
      ctx

    existing ->
      IO.puts("Context already exists: #{existing.name} (#{existing.slug})")
      existing
  end

ctx_id = context.id

# ──────────────────────────────────────────────────────────────────────────
# Helper: idempotent page creation
# ──────────────────────────────────────────────────────────────────────────

defmodule Seeder do
  @moduledoc """
  Idempotent seed helpers. Each creator checks existence by slug within the
  workspace before inserting.
  """

  @doc "Create a page only if it doesn't already exist (by slug within context)."
  def page!(workspace_id, attrs) do
    slug = attrs["slug"] || attrs[:slug]

    case Dran.Knowledge.get_page_by_slug(slug, workspace_id) do
      nil ->
        {:ok, page} = Dran.Knowledge.create_page(Map.put(attrs, "workspace_id", workspace_id))
        IO.puts("  ✓ Created #{page.page_type}: #{page.slug}")
        page

      existing ->
        IO.puts("  · Exists   #{existing.page_type}: #{existing.slug}")
        existing
    end
  end

  @doc "Create a relation by slugs (idempotent via on_conflict: :nothing)."
  def rel!(workspace_id, source_slug, target_slug, type \\ "related") do
    Dran.Knowledge.create_relation_by_slugs(source_slug, target_slug, type, workspace_id)
  end
end

IO.puts("\nSeeding context '#{workspace_slug}' with realistic content...\n")

# ──────────────────────────────────────────────────────────────────────────
# 3. Notes (5+) with embeds ![[slug]] between them
# ──────────────────────────────────────────────────────────────────────────

IO.puts("\nNotes:")

note_zettelkasten =
  Seeder.page!(ctx_id, %{
    "slug" => "nota-metodo-zettelkasten",
    "title" => "El método Zettelkasten",
    "page_type" => "note",
    "body" => """
    # El método Zettelkasten

    El Zettelkasten (caja de fichas en alemán) es un sistema de toma de notas
    desarrollado por Niklas Luhmann, un sociólogo que escribió más de 70 libros
    y 400 artículos usando este método.

    ## Principios clave

    1. **Atomicidad**: cada nota contiene una sola idea
    2. **Conexión**: las notas se enlazan entre sí formando un grafo
    3. **Emergencia**: el conocimiento surge de las conexiones, no de las notas aisladas

    La idea central es que el valor no está en las notas individuales sino en
    la red de conexiones que se forma entre ellas.

    ![[concepto-segundo-cerebro]]

    También conecta con el concepto de ![[concepto-grafo-de-conocimiento]].
    """,
    "summary" =>
      "Sistema de notas interconectadas desarrollado por Niklas Luhmann basado en atomicidad y conexiones.",
    "tags" => ["productividad", "conocimiento", "zettelkasten", "metodo"],
    "meta" => %{"kind" => "idea"},
    "owner" => "alvaro",
    "created_by" => "alvaro"
  })

note_para_method =
  Seeder.page!(ctx_id, %{
    "slug" => "nota-metodo-para",
    "title" => "El método PARA de Tiago Forte",
    "page_type" => "note",
    "body" => """
    # El método PARA

    PARA es un sistema de organización desarrollado por Tiago Forte, descrito
    en su libro "Building a Second Brain".

    ## Las cuatro categorías

    - **Projects** — tareas activas con deadline
    - **Areas** — responsabilidades continuas
    - **Resources** — temas de interés
    - **Archives** — items inactivos

    La clave es que todo se mueve entre estas categorías según su relevancia
    actual. Es un sistema dinámico, no estático.

    ![[concepto-segundo-cerebro]]

    Comparado con ![[nota-metodo-zettelkasten]], PARA se enfoca más en la
    organización práctica que en las conexiones semánticas.
    """,
    "summary" => "Sistema de organización (Projects, Areas, Resources, Archives) de Tiago Forte.",
    "tags" => ["productividad", "conocimiento", "para", "metodo"],
    "meta" => %{"kind" => "idea"},
    "owner" => "alvaro",
    "created_by" => "alvaro"
  })

note_daily_standup =
  Seeder.page!(ctx_id, %{
    "slug" => "nota-reflexion-productividad-diaria",
    "title" => "Reflexión: la trampa de la productividad",
    "page_type" => "note",
    "body" => """
    # La trampa de la productividad

    A veces me encuentro optimizando sistemas en lugar de hacer el trabajo real.
    Es importante recordar que el sistema es un medio, no un fin.

    ## Señales de alerta
    - Pasar más tiempo organizando que creando
    - Cambiar de herramienta constantemente
    - Sentir que "casi" tengo el sistema perfecto

    La solución: limitar el tiempo de mantenimiento del sistema a 30 min/día
    y enfocarse en producir.

    ![[nota-metodo-para]]
    ![[nota-metodo-zettelkasten]]

    Estos métodos son útiles solo si sirven al trabajo creativo.
    """,
    "summary" =>
      "Reflexión sobre cómo la obsesión por optimizar sistemas puede ser contraproducente.",
    "tags" => ["productividad", "reflexion", "filosofia"],
    "meta" => %{"kind" => "journal", "mood" => "reflective"},
    "owner" => "alvaro",
    "created_by" => "alvaro"
  })

note_elixir_pattern =
  Seeder.page!(ctx_id, %{
    "slug" => "nota-patron-genserver-elixir",
    "title" => "Patrón GenServer en Elixir",
    "page_type" => "note",
    "body" => """
    # GenServer en Elixir

    Un GenServer es un proceso que implementa el modelo cliente-servidor.
    Mantiene estado, maneja llamadas síncronas (call) y asíncronas (cast).

    ## Estructura básica

    ```elixir
    defmodule Counter do
      use GenServer

      def start_link(initial), do: GenServer.start_link(__MODULE__, initial, name: __MODULE__)
      def increment, do: GenServer.cast(__MODULE__, :increment)
      def value, do: GenServer.call(__MODULE__, :value)

      @impl true
      def init(initial), do: {:ok, initial}

      @impl true
      def handle_cast(:increment, state), do: {:noreply, state + 1}

      @impl true
      def handle_call(:value, _from, state), do: {:reply, state, state}
    end
    ```


    El concepto de actores se explica en ![[concepto-modelo-actores]].
    """,
    "summary" =>
      "GenServer implementa el modelo cliente-servidor con estado, llamadas síncronas y asíncronas.",
    "tags" => ["elixir", "programacion", "genserver", "patron"],
    "meta" => %{"kind" => "technical"},
    "owner" => "alvaro",
    "created_by" => "alvaro"
  })

note_writing_routine =
  Seeder.page!(ctx_id, %{
    "slug" => "nota-rutina-escritura-manana",
    "title" => "Mi rutina de escritura matutina",
    "page_type" => "note",
    "body" => """
    # Rutina de escritura matutina

    He descubierto que escribir por la mañana, antes de revisar el correo o
    las redes sociales, produce mis mejores textos.

    ## La rutina (6:00 - 7:30)
    1. Café y revisión del diario del día anterior
    2. 15 min de lectura inspiradora
    3. 45 min de escritura sin distracciones
    4. 15 min de revisión y edición
    5. Planificar el día

    Las ideas sobre productividad de ![[nota-reflexion-productividad-diaria]]
    me ayudaron a diseñar esta rutina sin obsesionarme con la perfección.
    """,
    "summary" =>
      "Rutina de escritura matutina de 90 minutos que produce los mejores resultados creativos.",
    "tags" => ["escritura", "rutina", "productividad", "habitos"],
    "meta" => %{"kind" => "journal"},
    "owner" => "alvaro",
    "created_by" => "alvaro"
  })

# ──────────────────────────────────────────────────────────────────────────
# 4. Concepts (3) with semantic relations
# ──────────────────────────────────────────────────────────────────────────

IO.puts("\nConcepts:")

concept_segundo_cerebro =
  Seeder.page!(ctx_id, %{
    "slug" => "concepto-segundo-cerebro",
    "title" => "Segundo Cerebro",
    "page_type" => "concept",
    "body" => """
    # Segundo Cerebro

    Un "segundo cerebro" es un sistema de gestión de conocimiento personal
    que externaliza la memoria y facilita la conexión de ideas.

    El término fue popularizado por Tiago Forte y se basa en la idea de que
    nuestra memoria biológica es para generar ideas, no para almacenarlas.

    ## Componentes
    - Captura: recolectar información de múltiples fuentes
    - Organización: estructurar con sistemas como ![[nota-metodo-para]]
    - Conexión: enlazar ideas como en ![[nota-metodo-zettelkasten]]
    - Recuperación: encontrar y usar el conocimiento cuando se necesita

    Un segundo cerebro se implementa como un ![[concepto-grafo-de-conocimiento]].
    """,
    "summary" =>
      "Sistema de gestión de conocimiento personal que externaliza la memoria y conecta ideas.",
    "tags" => ["conocimiento", "productividad", "sistema"],
    "owner" => "alvaro",
    "created_by" => "alvaro"
  })

concept_grafo =
  Seeder.page!(ctx_id, %{
    "slug" => "concepto-grafo-de-conocimiento",
    "title" => "Grafo de Conocimiento",
    "page_type" => "concept",
    "body" => """
    # Grafo de Conocimiento

    Un grafo de conocimiento representa información como nodos (entidades,
    conceptos) y aristas (relaciones) que los conectan.

    A diferencia de una estructura jerárquica (carpetas), un grafo permite:
    - Múltiples caminos hacia la misma información
    - Relaciones semánticas entre conceptos distantes
    - Descubrimiento de conexiones inesperadas

    En el contexto de un ![[concepto-segundo-cerebro]], el grafo emerge
    naturalmente al enlazar notas y crear relaciones.

    El modelo de actores de ![[concepto-modelo-actores]] comparte la filosofía
    de sistemas distribuidos con nodos autónomos que se comunican.
    """,
    "summary" =>
      "Estructura de datos que representa conocimiento como nodos y aristas, permitiendo conexiones semánticas.",
    "tags" => ["grafo", "conocimiento", "estructura", "datos"],
    "owner" => "alvaro",
    "created_by" => "alvaro"
  })

concept_actores =
  Seeder.page!(ctx_id, %{
    "slug" => "concepto-modelo-actores",
    "title" => "Modelo de Actores",
    "page_type" => "concept",
    "body" => """
    # Modelo de Actores

    El modelo de actores es un modelo de computación concurrente donde "actores"
    son la unidad universal de cómputo.

    ## Características
    - Cada actor tiene estado privado
    - Los actores se comunican mediante mensajes asíncronos
    - En respuesta a un mensaje, un actor puede: enviar mensajes, crear más
      actores, o cambiar su comportamiento

    Este modelo es la base de la concurrencia en Erlang/Elixir (BEAM VM).

    Relacionado con ![[nota-patron-genserver-elixir]].

    Al igual que un ![[concepto-grafo-de-conocimiento]], los actores forman
    una red de nodos que se comunican.
    """,
    "summary" =>
      "Modelo de computación concurrente con actores que tienen estado privado y se comunican por mensajes.",
    "tags" => ["programacion", "concurrencia", "elixir", "actores"],
    "owner" => "alvaro",
    "created_by" => "alvaro"
  })

# ──────────────────────────────────────────────────────────────────────────
# 5. Explicit relations (semantic, related, part_of)
# ──────────────────────────────────────────────────────────────────────────

IO.puts("\nRelations:")

# Related: concepts to notes
Seeder.rel!(ctx_id, "concepto-segundo-cerebro", "nota-metodo-zettelkasten", "related")
Seeder.rel!(ctx_id, "concepto-segundo-cerebro", "nota-metodo-para", "related")
Seeder.rel!(ctx_id, "concepto-grafo-de-conocimiento", "concepto-segundo-cerebro", "related")
Seeder.rel!(ctx_id, "concepto-modelo-actores", "nota-patron-genserver-elixir", "related")

# Semantic: concept-to-concept (manual, since inference may not be configured)
Seeder.rel!(ctx_id, "concepto-segundo-cerebro", "concepto-grafo-de-conocimiento", "semantic")
Seeder.rel!(ctx_id, "concepto-grafo-de-conocimiento", "concepto-modelo-actores", "semantic")
Seeder.rel!(ctx_id, "concepto-segundo-cerebro", "concepto-modelo-actores", "semantic")

IO.puts("  ✓ Relations created (related, semantic, part_of, embeds)")

# ──────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────

total_pages =
  Repo.aggregate(
    from(p in Dran.Knowledge.Page, where: p.workspace_id == ^ctx_id),
    :count
  )

total_relations =
  Repo.aggregate(
    from(r in Dran.Relation, join: p in assoc(r, :source), where: p.workspace_id == ^ctx_id),
    :count
  )

IO.puts("""

╔══════════════════════════════════════════════╗
║  Seeds completados ✓                         ║
║  Contexto: #{context_name} (#{workspace_slug})           ║
║  Páginas totales: #{total_pages}                          ║
║  Relaciones totales: #{total_relations}                       ║
╚══════════════════════════════════════════════╝
""")
