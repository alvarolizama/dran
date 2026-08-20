# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Creates the default context and seeds it with realistic Spanish content:
# goals with nested todos, notes with embeds, concepts with semantic relations.
# Idempotent — safe to run multiple times.
#
# Admin users are NOT created here: the first-run /setup web flow handles
# initial admin creation.

import Ecto.Query
alias Dran.Repo
alias Dran.Brain
alias Dran.Brain.{Context, Page, Relation}

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
  case Repo.get_by(Context, slug: workspace_slug) do
    nil ->
      {:ok, ctx} = Brain.create_workspace(%{name: context_name, slug: workspace_slug})
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
  @doc "Create a page only if it doesn't already exist (by slug within context)."
  def page!(workspace_id, attrs) do
    slug = attrs["slug"] || attrs[:slug]

    case Dran.Brain.get_page_by_slug(slug, workspace_id) do
      nil ->
        {:ok, page} = Dran.Brain.create_page(Map.put(attrs, "workspace_id", workspace_id))
        IO.puts("  ✓ Created #{page.page_type}: #{page.slug}")
        page

      existing ->
        IO.puts("  · Exists   #{existing.page_type}: #{existing.slug}")
        existing
    end
  end

  @doc "Create a relation by slugs (idempotent via on_conflict: :nothing)."
  def rel!(workspace_id, source_slug, target_slug, type \\ "related") do
    Dran.Brain.create_relation_by_slugs(source_slug, target_slug, type, workspace_id)
  end
end

IO.puts("\nSeeding context '#{workspace_slug}' with realistic content...\n")

# ──────────────────────────────────────────────────────────────────────────
# 1. Goals (3) with kanban_status
# ──────────────────────────────────────────────────────────────────────────

IO.puts("Goals:")

goal_aprender_elixir =
  Seeder.page!(ctx_id, %{
    "slug" => "goal-aprender-elixir-phoenix",
    "title" => "Aprender Elixir y Phoenix",
    "page_type" => "goal",
    "body" => """
    # Aprender Elixir y Phoenix

    Dominar el stack Elixir + Phoenix + LiveView para construir aplicaciones
    concurrentes y en tiempo real.

    ## Objetivos específicos
    - Comprender el modelo de concurrencia con actores (GenServer, Supervisor)
    - Construir una LiveView completa con pubsub
    - Desplegar en producción con releases

    ## Recursos
    - Programming Phoenix LiveView (Bruce Tate)
    - Elixir in Action (Saša Jurić)
    - Hexdocs oficial
    """,
    "summary" =>
      "Dominar Elixir, Phoenix y LiveView para construir apps concurrentes en tiempo real.",
    "tags" => ["programacion", "elixir", "phoenix", "aprendizaje"],
    "meta" => %{
      "kanban_status" => "in_progress",
      "target_date" => "2026-09-30",
      "health" => "green"
    },
    "owner" => "alvaro",
    "created_by" => "alvaro"
  })

goal_escribir_libro =
  Seeder.page!(ctx_id, %{
    "slug" => "goal-escribir-libro-segundo-cerebro",
    "title" => "Escribir libro sobre Segundo Cerebro",
    "page_type" => "goal",
    "body" => """
    # Escribir libro: Construyendo tu Segundo Cerebro

    Un libro práctico sobre cómo implementar un sistema de gestión de conocimiento
    personal usando metodologías Zettelkasten, PARA y herramientas digitales.

    ## Estructura propuesta
    1. Introducción: Por qué necesitas un segundo cerebro
    2. Capturar: Recolección de información
    3. Organizar: Sistemas y estructuras
    4. Destilar: Resúmenes y conexiones
    5. Expresar: Crear a partir del conocimiento

    ## Estado
    Borrador del capítulo 1 completo. Trabajando en capítulo 2.
    """,
    "summary" =>
      "Libro práctico sobre sistemas de gestión de conocimiento personal (Zettelkasten, PARA).",
    "tags" => ["escritura", "libro", "conocimiento", "zettelkasten"],
    "meta" => %{
      "kanban_status" => "in_progress",
      "target_date" => "2026-12-31",
      "health" => "yellow"
    },
    "owner" => "alvaro",
    "created_by" => "alvaro"
  })

goal_mejorar_salud_fisica =
  Seeder.page!(ctx_id, %{
    "slug" => "goal-mejorar-salud-fisica",
    "title" => "Mejorar salud física",
    "page_type" => "goal",
    "body" => """
    # Mejorar salud física

    Establecer una rutina sostenible de ejercicio y alimentación.

    ## Metas
    - Correr 5K sin parar
    - 3 sesiones de fuerza por semana
    - Dormir 7+ horas diarias
    - Reducir azúcar procesado

    ## Progreso
    Actualmente corriendo 3K. Mejorando la consistencia.
    """,
    "summary" =>
      "Rutina sostenible de ejercicio, alimentación y descanso para mejorar la salud física.",
    "tags" => ["salud", "fitness", "bienestar"],
    "meta" => %{
      "kanban_status" => "backlog",
      "target_date" => "2026-10-15",
      "health" => "green"
    },
    "owner" => "alvaro",
    "created_by" => "alvaro"
  })

# ──────────────────────────────────────────────────────────────────────────
# 2. Todos (nested under goals via meta.goal_slug)
# ──────────────────────────────────────────────────────────────────────────

IO.puts("\nTodos:")

Seeder.page!(ctx_id, %{
  "slug" => "todo-completar-curso-elixir-school",
  "title" => "Completar curso de Elixir School",
  "page_type" => "todo",
  "body" =>
    "Avanzar en las lecciones de https://elixirschool.com/es/ hasta completar el módulo de GenServer.",
  "tags" => ["elixir", "aprendizaje"],
  "meta" => %{"kanban_status" => "done", "goal_slug" => "goal-aprender-elixir-phoenix"},
  "owner" => "alvaro",
  "created_by" => "alvaro"
})

Seeder.page!(ctx_id, %{
  "slug" => "todo-construir-app-liveview-tareas",
  "title" => "Construir app LiveView de tareas",
  "page_type" => "todo",
  "body" =>
    "Crear una pequeña aplicación de gestión de tareas con Phoenix LiveView para practicar pubsub y assigns.",
  "tags" => ["elixir", "phoenix", "proyecto"],
  "meta" => %{"kanban_status" => "in_progress", "goal_slug" => "goal-aprender-elixir-phoenix"},
  "owner" => "alvaro",
  "created_by" => "alvaro"
})

Seeder.page!(ctx_id, %{
  "slug" => "todo-leer-programming-phoenix-liveview",
  "title" => "Leer Programming Phoenix LiveView",
  "page_type" => "todo",
  "body" => "Terminar de leer el libro de Bruce Tate. Capítulos pendientes: 7, 8, 9.",
  "tags" => ["lectura", "elixir", "phoenix"],
  "meta" => %{"kanban_status" => "pending", "goal_slug" => "goal-aprender-elixir-phoenix"},
  "owner" => "alvaro",
  "created_by" => "alvaro"
})

Seeder.page!(ctx_id, %{
  "slug" => "todo-borrador-capitulo-1-libro",
  "title" => "Borrador capítulo 1 del libro",
  "page_type" => "todo",
  "body" =>
    "Escribir el primer borrador del capítulo introductorio del libro sobre segundo cerebro.",
  "tags" => ["escritura", "libro"],
  "meta" => %{"kanban_status" => "done", "goal_slug" => "goal-escribir-libro-segundo-cerebro"},
  "owner" => "alvaro",
  "created_by" => "alvaro"
})

Seeder.page!(ctx_id, %{
  "slug" => "todo-esquema-capitulo-2",
  "title" => "Esquema del capítulo 2: Capturar",
  "page_type" => "todo",
  "body" => "Definir la estructura y puntos clave del capítulo sobre captura de información.",
  "tags" => ["escritura", "libro"],
  "meta" => %{
    "kanban_status" => "in_progress",
    "goal_slug" => "goal-escribir-libro-segundo-cerebro"
  },
  "owner" => "alvaro",
  "created_by" => "alvaro"
})

Seeder.page!(ctx_id, %{
  "slug" => "todo-rutina-correr-3x-semana",
  "title" => "Correr 3 veces por semana",
  "page_type" => "todo",
  "body" =>
    "Establecer rutina de carrera: martes, jueves y sábado. Empezar con 3K y aumentar gradualmente.",
  "tags" => ["salud", "fitness"],
  "meta" => %{"kanban_status" => "pending", "goal_slug" => "goal-mejorar-salud-fisica"},
  "owner" => "alvaro",
  "created_by" => "alvaro"
})

Seeder.page!(ctx_id, %{
  "slug" => "todo-ajustar-dieta-reducir-azucar",
  "title" => "Ajustar dieta: reducir azúcar procesado",
  "page_type" => "todo",
  "body" => "Eliminar refrescos y reducir postres. Sustituir por frutas y snacks saludables.",
  "tags" => ["salud", "nutricion"],
  "meta" => %{"kanban_status" => "backlog", "goal_slug" => "goal-mejorar-salud-fisica"},
  "owner" => "alvaro",
  "created_by" => "alvaro"
})

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

    Relacionado con mi objetivo de ![[goal-escribir-libro-segundo-cerebro]].

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

    Relacionado con ![[goal-aprender-elixir-phoenix]].

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

    Esta rutina alimenta directamente ![[goal-escribir-libro-segundo-cerebro]].

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

    Relacionado con ![[nota-patron-genserver-elixir]] y con el objetivo de
    ![[goal-aprender-elixir-phoenix]].

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

# Part_of: todos are part of goals
Seeder.rel!(
  ctx_id,
  "todo-completar-curso-elixir-school",
  "goal-aprender-elixir-phoenix",
  "part_of"
)

Seeder.rel!(
  ctx_id,
  "todo-construir-app-liveview-tareas",
  "goal-aprender-elixir-phoenix",
  "part_of"
)

Seeder.rel!(
  ctx_id,
  "todo-leer-programming-phoenix-liveview",
  "goal-aprender-elixir-phoenix",
  "part_of"
)

Seeder.rel!(
  ctx_id,
  "todo-borrador-capitulo-1-libro",
  "goal-escribir-libro-segundo-cerebro",
  "part_of"
)

Seeder.rel!(ctx_id, "todo-esquema-capitulo-2", "goal-escribir-libro-segundo-cerebro", "part_of")
Seeder.rel!(ctx_id, "todo-rutina-correr-3x-semana", "goal-mejorar-salud-fisica", "part_of")
Seeder.rel!(ctx_id, "todo-ajustar-dieta-reducir-azucar", "goal-mejorar-salud-fisica", "part_of")

# Related: notes to goals
Seeder.rel!(
  ctx_id,
  "nota-rutina-escritura-manana",
  "goal-escribir-libro-segundo-cerebro",
  "related"
)

Seeder.rel!(ctx_id, "nota-patron-genserver-elixir", "goal-aprender-elixir-phoenix", "related")
Seeder.rel!(ctx_id, "nota-reflexion-productividad-diaria", "goal-mejorar-salud-fisica", "related")

IO.puts("  ✓ Relations created (related, semantic, part_of, embeds)")

# ──────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────

total_pages =
  Repo.aggregate(
    from(p in Page, where: p.workspace_id == ^ctx_id),
    :count
  )

total_relations =
  Repo.aggregate(
    from(r in Relation, join: p in assoc(r, :source), where: p.workspace_id == ^ctx_id),
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
