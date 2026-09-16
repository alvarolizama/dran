# Demo seed — llena una instancia local con datos realistas para navegar.
#
#     mix run priv/repo/seeds_demo.exs
#
# Distinto de `seeds.exs` (contenido mínimo sobre el workspace por defecto):
# este crea un workspace de trabajo completo — páginas de TODOS los tipos con
# sus kinds, relaciones tipadas, colecciones, memorias con distintos niveles de
# trust y facts de varios agentes — para probar la UI, la búsqueda, el grafo y
# los filtros de visibilidad.
#
# Idempotente: cada pieza se busca por slug/nombre antes de crear, así que se
# puede correr varias veces sin duplicar.

import Ecto.Query
alias Dran.{Repo, Knowledge, Memory, Collections}

ws_slug = "demo"
ws_name = "Demo"

# ──────────────────────────────────────────────────────────────────────────
# Workspace
# ──────────────────────────────────────────────────────────────────────────

workspace =
  case Knowledge.get_workspace_by_slug(ws_slug) do
    nil ->
      {:ok, ws} = Knowledge.create_workspace(%{name: ws_name, slug: ws_slug})
      IO.puts("✓ workspace creado: #{ws.slug}")
      ws

    %{} = ws ->
      IO.puts("· workspace ya existe: #{ws.slug} (#{ws.id})")
      ws
  end

ws_id = workspace.id

# Helpers idempotentes
defmodule Demo do
  def page!(ws_id, attrs) do
    slug = attrs["slug"]

    case Dran.Knowledge.get_page_by_slug(slug, ws_id) do
      nil ->
        {:ok, p} = Dran.Knowledge.create_page(Map.put(attrs, "workspace_id", ws_id))
        IO.puts("  ✓ #{p.page_type}: #{p.slug}")
        p

      existing ->
        IO.puts("  · ya existe: #{existing.slug}")
        existing
    end
  end

  def rel!(ws_id, source, target, type, description \\ nil) do
    case Dran.Knowledge.create_relation_by_slugs(source, target, type, ws_id) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  def memory!(ws_id, content, opts \\ []) do
    attrs = %{
      "workspace_id" => ws_id,
      "content" => content,
      "created_by" => Keyword.get(opts, :agent, "demo-agent")
    }

    attrs =
      if owner = Keyword.get(opts, :owner_user_id),
        do: Map.put(attrs, "owner_user_id", owner),
        else: attrs

    case Dran.Memory.add(attrs, force: true) do
      {:ok, m, :created} ->
        # trust/retrieval a un valor realista para que el ranking se note
        if score = Keyword.get(opts, :trust_score) do
          Dran.Memory.record_feedback(m.id, score > 0.5)
        end

        IO.puts("  ✓ memoria (#{String.slice(content, 0, 40)}…)")
        m

      {:ok, _existing, :duplicate} ->
        IO.puts("  · memoria duplicada")
        :duplicate

      {:error, e} ->
        IO.puts("  ✗ memoria falló: #{inspect(e)}")
        nil
    end
  end

  def collection!(ws_id, name, attrs \\ %{}) do
    slug = Dran.Slug.slugify(name)

    case Dran.Collections.get_collection_by_slug(slug, ws_id) do
      nil ->
        {:ok, c} = Dran.Collections.create_collection(Map.merge(%{"name" => name, "workspace_id" => ws_id}, attrs))
        IO.puts("  ✓ colección: #{c.name}")
        c

      existing ->
        IO.puts("  · colección ya existe: #{existing.name}")
        existing
    end
  end
end

IO.puts("\n── Notas ──────────────────────────────────────")

Demo.page!(ws_id, %{
  "slug" => "reunion-semanal-equipo",
  "title" => "Reunión semanal del equipo",
  "page_type" => "note",
  "body" => """
  # Reunión semanal — 2026-09-16

  ## Temas tratados

  - Estado del release de octubre, bloqueado por la migración de
    ![[plan-migracion-postgres]]
  - Decisión: mover el cierre de sprint a los jueves
  - El equipo pidió más tiempo para revisión de código

  ## Acuerdos

  1. Álvaro revisa el PR de particionado antes del viernes
  2. Se pospone la charla de arquitectura una semana
  3. Documento de ![[arquitectura-decisiones]] queda como referencia
  """,
  "tags" => ["equipo", "reuniones"],
  "meta" => %{"kind" => "journal", "date" => "2026-09-16"},
  "created_by" => "alvaro"
})

Demo.page!(ws_id, %{
  "slug" => "rutina-de-trabajo-profundo",
  "title" => "Rutina de trabajo profundo",
  "page_type" => "note",
  "body" => """
  # Trabajo profundo

  Bloques de 90 minutos sin interrupciones, dos por día como máximo.

  ## Reglas

  - Slack cerrado, notificaciones apagadas
  - Un solo tema por bloque
  - Escribir la intención al empezar el bloque

  Funciona porque el contexto de ![[arquitectura-decisiones]] ya está
  escrito y no tengo que reconstruirlo cada vez.
  """,
  "tags" => ["productividad", "foco"],
  "meta" => %{"kind" => "journal"},
  "created_by" => "alvaro"
})

IO.puts("\n── Ideas ──────────────────────────────────────")

Demo.page!(ws_id, %{
  "slug" => "idea-grafo-de-agentes",
  "title" => "¿Y si los agentes compartieran el grafo en tiempo real?",
  "page_type" => "idea",
  "body" => """
  # Grafo compartido en vivo

  Cada agente escribe y los demás ven los nodos aparecer en el grafo 3D
  mientras trabajan. Sería una forma visual de entender qué está haciendo
  el enjambre en un momento dado.

  Relacionado con ![[concepto-memoria-compartida]].
  """,
  "tags" => ["producto", "agentes"],
  "meta" => %{"kind" => "hypothesis"},
  "created_by" => "alvaro"
})

Demo.page!(ws_id, %{
  "slug" => "idea-medir-valor-del-brain",
  "title" => "Métrica: ¿cuánto recupera el brain por sí solo?",
  "page_type" => "idea",
  "body" => """
  # Valor de un segundo cerebro

  ¿Cómo medir si el brain sirve? Una métrica simple: de los hechos que un
  agente recuerda, ¿cuántos los habría perdido sin el brain?

  Ligado a ![[concepto-memoria-compartida]] y a ![[tecnica-rrf]].
  """,
  "tags" => ["producto", "metricas"],
  "meta" => %{"kind" => "question"},
  "created_by" => "alvaro"
})

IO.puts("\n── Conocimiento ───────────────────────────────")

Demo.page!(ws_id, %{
  "slug" => "cita-los-dos-sistemas",
  "title" => "«Un sistema que todo lo recuerda no es un sistema»",
  "page_type" => "knowledge",
  "body" => """
  # Cita

  > La memoria es un acto de selección, no de acumulación. Un archivo que
  > recuerda todo no ayuda a nadie.

  Contexto de la idea de que el valor está en las conexiones, no en el
  volumen — la misma intuición detrás de ![[concepto-memoria-compartida]].
  """,
  "tags" => ["citas", "conocimiento"],
  "meta" => %{"kind" => "quote", "source_url" => "https://example.org/memoria"},
  "created_by" => "alvaro"
})

Demo.page!(ws_id, %{
  "slug" => "resumen-libro-gestion-conocimiento",
  "title" => "Resumen: gestión del conocimiento personal",
  "page_type" => "knowledge",
  "body" => """
  # Gestión del conocimiento personal

  Los sistemas de notas personales fallan por dos razones: el coste de
  entrada (fricción para capturar) y el coste de salida (no encontrar nada
  después).

  ## Los dos costes

  | Coste | Síntoma | Remedio |
  |---|---|---|
  | Entrada | «lo anoto luego» | captura en un paso |
  | Salida | «sé que lo escribí» | búsqueda semántica |

  Dran ataca el segundo con ![[tecnica-rrf]].
  """,
  "tags" => ["libros", "conocimiento"],
  "meta" => %{"kind" => "summary"},
  "created_by" => "alvaro"
})

IO.puts("\n── Técnicas ───────────────────────────────────")

Demo.page!(ws_id, %{
  "slug" => "tecnica-rrf",
  "title" => "Reciprocal Rank Fusion (RRF)",
  "page_type" => "technical",
  "body" => """
  # RRF — fusionar rankings de buscadores distintos

  RRF combina varios rankings sin comparar sus puntajes (que no son
  comparables): cada documento suma `1 / (k + posición)`, con `k = 60` por
  convención.

  ```
  score(d) = Σ_rankings 1 / (60 + rank_i(d))
  ```

  ## Por qué funciona

  No necesita calibrar los puntajes de cada buscador: solo el orden. Es la
  técnica que permite mezclar full-text y búsqueda vectorial en
  ![[patron-busqueda-hibrida]].
  """,
  "tags" => ["busqueda", "algoritmos"],
  "meta" => %{"kind" => "code", "language" => "python"},
  "created_by" => "alvaro"
})

Demo.page!(ws_id, %{
  "slug" => "patron-busqueda-hibrida",
  "title" => "Patrón: búsqueda híbrida en Postgres",
  "page_type" => "technical",
  "body" => """
  # Búsqueda híbrida

  Dos índices, dos estrategias, una respuesta:

  1. **Full-text** (`tsvector` + GIN) — encontrás las palabras exactas
  2. **Vectorial** (pgvector + HNSW) — encontrás el significado parecido

  Se fusionan con ![[tecnica-rrf]] y se reordenan por confianza del
  respecto al tema.

  ## Configuración pgvector

  ```sql
  CREATE INDEX ON knowledge_pages
    USING hnsw (embedding vector_cosine_ops);
  ```
  """,
  "tags" => ["postgres", "busqueda", "vectorial"],
  "meta" => %{"kind" => "pattern", "language" => "sql"},
  "created_by" => "alvaro"
})

Demo.page!(ws_id, %{
  "slug" => "plan-migracion-postgres",
  "title" => "Plan: migrar a Postgres 18 con particiones",
  "page_type" => "technical",
  "body" => """
  # Migración a Postgres 18

  ## Pasos

  1. `pg_upgrade` en staging, medir downtime
  2. Aplicar particionado por rango en las tablas de log
  3. Probar el rollback completo antes de tocar producción

  ## Riesgos

  - Las particiones rompen las FKs existentes si no se recrean
  - Ver ![[patron-busqueda-hibrida]] para el índice HNSW tras la migración
  """,
  "tags" => ["postgres", "infraestructura"],
  "meta" => %{"kind" => "recipe", "version" => "18"},
  "created_by" => "coder-agent"
})

IO.puts("\n── Entidades ──────────────────────────────────")

Demo.page!(ws_id, %{
  "slug" => "entidad-elixir",
  "title" => "Elixir",
  "page_type" => "entity",
  "body" => """
  # Elixir

  Lenguaje funcional sobre la BEAM (máquina virtual de Erlang). Su fuerte es
  la concurrencia por procesos ligeros y la tolerancia a fallos por
  supervisión.

  ## Ecosistema

  - Phoenix para web — ![[entidad-phoenix]]
  - Postgres como base — ![[entidad-postgresql]]
  """,
  "tags" => ["lenguajes", "programacion"],
  "meta" => %{"kind" => "language", "external_url" => "https://elixir-lang.org"},
  "created_by" => "alvaro"
})

Demo.page!(ws_id, %{
  "slug" => "entidad-phoenix",
  "title" => "Phoenix",
  "page_type" => "entity",
  "body" => """
  # Phoenix

  Framework web de Elixir (![[entidad-elixir]]). La parte de LiveView
  mantiene el estado en el servidor y envía solo los diffs al navegador.

  Framework del proyecto del trabajo.
  """,
  "tags" => ["frameworks", "web"],
  "meta" => %{"kind" => "framework", "external_url" => "https://phoenixframework.org"},
  "created_by" => "alvaro"
})

Demo.page!(ws_id, %{
  "slug" => "entidad-postgresql",
  "title" => "PostgreSQL",
  "page_type" => "entity",
  "body" => """
  # PostgreSQL

  Base de datos relacional. Con extensiones se vuelve suficiente para
  búsqueda híbrida: `pgvector` para vectores, `tsvector` para texto.

  Ver ![[patron-busqueda-hibrida]].
  """,
  "tags" => ["bases-de-datos"],
  "meta" => %{"kind" => "product", "external_url" => "https://postgresql.org"},
  "created_by" => "alvaro"
})

IO.puts("\n── Conceptos ──────────────────────────────────")

Demo.page!(ws_id, %{
  "slug" => "concepto-memoria-compartida",
  "title" => "Memoria compartida entre agentes",
  "page_type" => "concept",
  "body" => """
  # Memoria compartida

  Cuando varios agentes trabajan sobre el mismo proyecto, cada uno aprende
  cosas que los demás necesitan. Sin un store compartido, ese conocimiento
  muere con la sesión.

  ## El problema real

  No es el almacenamiento, es el **dedupe**: dos agentes describen el mismo
  hecho con palabras distintas. Sin deduplicación el store se llena de
  variantes y la búsqueda devuelve cinco versiones de lo mismo.

  Base de la idea ![[idea-grafo-de-agentes]].
  """,
  "tags" => ["arquitectura", "agentes"],
  "meta" => %{"domain" => "sistemas distribuidos"},
  "created_by" => "alvaro"
})

Demo.page!(ws_id, %{
  "slug" => "concepto-contexto-de-sesion",
  "title" => "Contexto de sesión vs memoria duradera",
  "page_type" => "concept",
  "body" => """
  # Contexto vs memoria

  El contexto de una sesión es efímero y caro: vive en la ventana del modelo
  y cuesta tokens en cada turno. La memoria duradera es persistente y barata
  de consultar, pero solo si se recupera lo relevante.

  La decisión de qué sube de contexto a memoria es la decisión de diseño
  central de ![[concepto-memoria-compartida]].
  """,
  "tags" => ["arquitectura", "llm"],
  "meta" => %{"domain" => "sistemas de agentes", "parent_concept" => "concepto-memoria-compartida"},
  "created_by" => "alvaro"
})

IO.puts("\n── Referencias ────────────────────────────────")

Demo.page!(ws_id, %{
  "slug" => "referencia-paper-rrf",
  "title" => "Paper: Reciprocal Rank Fusion",
  "page_type" => "reference",
  "body" => """
  # Reciprocal Rank Fusion outperforms Condorcet

  El paper original de Cormack et al. (2009) que define la técnica.

  Ver ![[tecnica-rrf]] para la versión corta.
  """,
  "tags" => ["papers", "busqueda"],
  "meta" => %{
    "kind" => "paper",
    "source_url" => "https://plg.uwaterloo.ca/~gvcormac/cormacksigir09-rrf.pdf",
    "published_at" => "2009-07-01"
  },
  "created_by" => "alvaro"
})

Demo.page!(ws_id, %{
  "slug" => "referencia-docs-pgvector",
  "title" => "Docs: pgvector",
  "page_type" => "reference",
  "body" => """
  # pgvector

  Documentación de la extensión de vectores para Postgres.

  Usada en ![[patron-busqueda-hibrida]].
  """,
  "tags" => ["docs", "postgres"],
  "meta" => %{
    "kind" => "website",
    "source_url" => "https://github.com/pgvector/pgvector"
  },
  "created_by" => "coder-agent"
})

IO.puts("\n── Cocina ─────────────────────────────────────")

Demo.page!(ws_id, %{
  "slug" => "receta-pan-de-masa-madre",
  "title" => "Pan de masa madre",
  "page_type" => "food",
  "body" => """
  # Pan de masa madre

  ## Ingredientes

  - 500 g de harina de trigo
  - 350 g de agua (70 % hidratación)
  - 100 g de masa madre activa
  - 10 g de sal

  ## Proceso

  1. Autólisis 30 min (harina + agua, sin sal)
  2. Mezclar masa madre y sal
  3. Pliegues cada 30 min × 3
  4. Fermentación en bloque 4 h a temperatura ambiente
  5. Formar y fermentar en frío 12 h
  6. Hornear 20 min tapado a 250 °C, 25 min destapado a 230 °C

  ## Notas

  Con 70 % de hidratación la masa queda manejable. Subir al 75 % da miga
  más abierta pero cuesta formar.
  """,
  "tags" => ["pan", "recetas"],
  "meta" => %{
    "kind" => "recipe",
    "cuisine" => "artesanal",
    "servings" => 1,
    "prep_time" => "45 min",
    "cook_time" => "45 min"
  },
  "created_by" => "alvaro"
})

Demo.page!(ws_id, %{
  "slug" => "ingrediente-masa-madre",
  "title" => "Masa madre",
  "page_type" => "food",
  "body" => """
  # Masa madre

  Cultivo de levaduras y bacterias lácticas mantenido con harina y agua.

  ## Mantenimiento

  - Refrescar cada 24 h si está a temperatura ambiente
  - Una vez por semana si vive en la nevera
  - Proporción 1:1:1 (madre : harina : agua)

  Usada en ![[receta-pan-de-masa-madre]].
  """,
  "tags" => ["fermentos", "cocina"],
  "meta" => %{"kind" => "ingredient"},
  "created_by" => "alvaro"
})

# ──────────────────────────────────────────────────────────────────────────
# Relaciones tipadas
# ──────────────────────────────────────────────────────────────────────────

IO.puts("\n── Relaciones ─────────────────────────────────")

[
  {"reunion-semanal-equipo", "plan-migracion-postgres", "related"},
  {"reunion-semanal-equipo", "patron-busqueda-hibrida", "related"},
  {"resumen-libro-gestion-conocimiento", "tecnica-rrf", "related"},
  {"concepto-memoria-compartida", "idea-grafo-de-agentes", "related"},
  {"concepto-contexto-de-sesion", "concepto-memoria-compartida", "part_of"},
  {"idea-medir-valor-del-brain", "concepto-memoria-compartida", "related"},
  {"patron-busqueda-hibrida", "tecnica-rrf", "part_of"},
  {"patron-busqueda-hibrida", "entidad-postgresql", "related"},
  {"cita-los-dos-sistemas", "concepto-memoria-compartida", "related"},
  {"entidad-phoenix", "entidad-elixir", "part_of"},
  {"plan-migracion-postgres", "entidad-postgresql", "related"},
  {"receta-pan-de-masa-madre", "ingrediente-masa-madre", "part_of"},
  {"referencia-paper-rrf", "tecnica-rrf", "related"},
  {"referencia-docs-pgvector", "patron-busqueda-hibrida", "related"},
  {"rutina-de-trabajo-profundo", "reunion-semanal-equipo", "related"},
  # una contradicción, para ver el tipo en el grafo
  {"idea-medir-valor-del-brain", "cita-los-dos-sistemas", "contradicts"}
]
|> Enum.each(fn {s, t, type} -> Demo.rel!(ws_id, s, t, type) end)

IO.puts("  ✓ relaciones creadas")

# ──────────────────────────────────────────────────────────────────────────
# Colecciones
# ──────────────────────────────────────────────────────────────────────────

IO.puts("\n── Colecciones ────────────────────────────────")

Demo.collection!(ws_id, "Trabajo", %{
  "summary" => "Reuniones, planes y decisiones del día a día",
  "filters" => %{"tag" => "equipo"}
})

Demo.collection!(ws_id, "Aprendizaje", %{
  "summary" => "Papers, libros y técnicas que vale la pena recordar",
  "filters" => %{"tag" => "busqueda"}
})

Demo.collection!(ws_id, "Cocina", %{
  "summary" => "Recetas e ingredientes",
  "filters" => %{"type" => "food"}
})

IO.puts("  ✓ colecciones listas")

# ──────────────────────────────────────────────────────────────────────────
# Memorias (con varios dueños/agentes, para probar la visibilidad)
# ──────────────────────────────────────────────────────────────────────────

IO.puts("\n── Memorias ───────────────────────────────────")

[
  {"El deploy de producción es los martes a las 10:00, nunca después de las 15:00",
   [agent: "coder-agent"]},
  {"Álvaro prefiere que los PRs grandes se dividan en commits atómicos antes de revisar",
   [agent: "coder-agent"]},
  {"El proyecto usa Phoenix 1.8 con LiveView; no introducir JavaScript de terceros sin justificarlo",
   [agent: "coder-agent"]},
  {"La base de staging se resetea cada domingo por la noche",
   [agent: "ops-agent"]},
  {"Las migraciones deben ser reversibles: si el down no funciona, la migración no entra",
   [agent: "coder-agent"]},
  {"Álvaro trabaja en bloques de mañana; las reuniones van después de las 13:00",
   [agent: "aluxe"]},
  {"El brain se consulta antes de escribir una página nueva, para no duplicar",
   [agent: "coder-agent"]},
  {"Los tests de particiones necesitan la DB de test con MIX_TEST_PARTITION para no pisarse",
   [agent: "coder-agent"]},
  {"La tolerancia a fallos importa más que el rendimiento en el ingest de memoria",
   [agent: "ops-agent"]},
  {"Cuando una decisión es difícil de revertir, se documenta en el brain con el porqué",
   [agent: "aluxe"]}
]
|> Enum.each(fn {content, opts} -> Demo.memory!(ws_id, content, opts) end)

# ──────────────────────────────────────────────────────────────────────────
# Resumen
# ──────────────────────────────────────────────────────────────────────────

total_pages =
  Repo.aggregate(from(p in Dran.Knowledge.Page, where: p.workspace_id == ^ws_id), :count)

total_relations =
  Repo.aggregate(
    from(r in Dran.Relation, join: p in assoc(r, :source), where: p.workspace_id == ^ws_id),
    :count
  )

total_memories =
  Repo.aggregate(from(m in Dran.Memory, where: m.workspace_id == ^ws_id), :count)

total_collections =
  Repo.aggregate(from(c in Dran.Collections.Collection, where: c.workspace_id == ^ws_id), :count)

types =
  Repo.all(
    from(p in Dran.Knowledge.Page,
      where: p.workspace_id == ^ws_id,
      group_by: p.page_type,
      select: {p.page_type, count(p.id)}
    )
  )

IO.puts("""

╔═══════════════════════════════════════════════════════════╗
║  Demo seed completo ✓                                     ║
╠═══════════════════════════════════════════════════════════╣
║  Workspace:  #{String.pad_trailing(workspace.slug, 43)}║
║  Páginas:    #{String.pad_trailing(Integer.to_string(total_pages), 43)}║
║  Relaciones: #{String.pad_trailing(Integer.to_string(total_relations), 43)}║
║  Memorias:   #{String.pad_trailing(Integer.to_string(total_memories), 43)}║
║  Colecciones:#{String.pad_trailing(Integer.to_string(total_collections), 43)}║
╚═══════════════════════════════════════════════════════════╝

  Por tipo: #{Enum.map_join(types, ", ", fn {t, n} -> "#{t}=#{n}" end)}

  Abrí: http://localhost:4001/#{workspace.slug}
""")
