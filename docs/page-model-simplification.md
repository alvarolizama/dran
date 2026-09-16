# Simplificación del modelo de Dran — 4 tipos de página, kinds fuera, tipos por workspace, API keys

**Fecha:** 2026-09-16 · **Repo:** `/Users/alvaro/Workspace/Repos/alvarolizama/dran`
**Estado del árbol al analizar:** `main`, working tree limpio, 26 commits por delante de `origin/main` (`0286755`).
**Alcance de este documento:** análisis técnico previo. El plan ejecutable vive en
`.riel/contract.md`; el estándar visual en `DESIGN.md`.

---

## 1. Lo que se decide

| # | Decisión | Efecto |
|---|---|---|
| D1 | **4 page types built-in**: `note`, `reference`, `entity`, `concept` | Se eliminan `idea`, `knowledge`, `technical`, `food` |
| D2 | **`meta.kind` desaparece por completo** | No queda como "legacy para display": se van el select, el filtro `?kind=`, la validación, los labels y las opciones |
| D3 | **Tipos custom por workspace** vía configuración del workspace | El workspace deja de solo *desactivar* tipos: ahora también *agrega* |
| D4 | `/settings/agents` → **`/settings/api-keys`** | Desaparece el CRUD de actores/agentes |
| D5 | **La API key no crea un actor** | `name` + matriz `api_key_workspaces` (read/write) sobre workspaces del usuario |
| D6 | **Quién escribe llega por la API** | `created_by` = header `X-Hermes-Agent`; si falta, el nombre de la key |

Lo que **no** cambia: `meta.props` (bolsa libre de propiedades, ortogonal a kind), las
relaciones tipadas, el grafo, los workers, la política de visibilidad de lectura
(`Dran.ContentVisibility`) y la atribución server-side (sigue siendo no-client-setteable).

---

## 2. Estado actual verificado

### 2.1 El registry es el centro de gravedad

`lib/dran/page_registry.ex` es la única fuente de verdad y hoy declara **8 tipos**
(`@types`, l.145) con **kinds** por tipo (`:kinds`, l.53-142):

| Tipo | kinds (l.) | meta_fields (l.) |
|---|---|---|
| `note` | `nil` (libre) | `date`, `due_date` cond. `{:kind,"reminder"}`, `props` (l.307) |
| `idea` | `idea question hypothesis spark` (l.67) | `kind` select, `props` (l.315) |
| `knowledge` | `quote summary highlight excerpt` (l.78) | `kind` select, `source_url`, `date`, `props` (l.322) |
| `technical` | `code snippet debug recipe config command template pattern method` (l.89) | `kind` select, `language` cond., `version`, `props` (l.331) |
| `entity` | `person company product tool place event language framework hardware protocol` (l.100) | `kind` select, `location`, `external_url`, `props` (l.349) |
| `concept` | `nil` (libre) | `domain`, `parent_concept`, `props` (l.341) |
| `reference` | `article paper video podcast book newsletter spec code release website repo api` (l.122) | `kind` select, `source_url`, `published_at`, `props` (l.358) |
| `food` | `recipe ingredient dish meal cuisine restaurant drink technique` (l.133) | `kind` select, `cuisine`, `servings`, `prep_time`, `cook_time`, `source_url`, `props` (l.367) |

Dos hechos relevantes para la migración:

1. **Los kinds están doblemente declarados** en `@registry` (`:kinds`) y en
   `kind_labels/0` (l.453-525). `kind_label/1` es un `Map.fetch!` (l.450): un kind sin
   label en una fila revienta la lista entera.
2. **La validación de kind no se ejecuta al persistir.**
   `Knowledge.create_page/1` castea `meta` como mapa plano y nunca llama a
   `PageMeta.changeset/3`; hoy un kind inválido se guarda sin error. Esto ya está
   documentado en `docs/page-types.md` (§ *Validation notes*). Consecuencia: eliminar
   la validación de kind no rompe ningún write path, solo el editor y los filtros.

### 2.2 La lista de tipos está replicada a mano en ~20 sitios

El registry se declara "single source of truth", pero el vocabulario se copia:

| Sitio | Línea | Qué copia |
|---|---|---|
| `lib/dran/page_types.ex` | 12-14 | moduledoc "exactly **4** page types: note, entity, concept, reference" — **ya desactualizado** (hay 8) |
| `lib/dran/knowledge/page.ex` | 7-17 | moduledoc con los 8 tipos |
| `lib/dran_web/page_types.ex` | — | solo presentación, delega |
| `assets/js/hooks/graph_3d.js` | 510-514 | `typePaths` con los 8 slugs |
| `lib/dran_web/live/search_live.ex` | 509-538 | `type_chip_bg/1`, `type_icon_color/1`, `type_badge/1` — una cláusula por tipo **+ una cláusula `"project"` muerta** (el tipo se eliminó) |
| `hermes_plugin/dran/__init__.py` | ~983, ~1014 | la lista de tipos en la descripción de `dran_list_pages` y `dran_create_page` |
| `docs/page-types.md` | — | el documento entero |
| `README.md` | ~114, ~131 | "Settings → Agents", tabla de tipos |

**Código muerto confirmado:** en el propio registry, `agent_description/0` (l.395),
`agent_enum/0` (l.415) y `agent_meta_description/0` (l.420) **no tienen ningún
consumidor** — el único match de sus nombres fuera de sus definiciones es el moduledoc
que las cita (l.19). Son residuo de la era MCP: la descripción de tipos que ve el agente
se construye en `hermes_plugin/dran/__init__.py` (~l.983 y ~l.1014), hardcodeada. W1 los
borra y, si se quiere que el agente conozca los tipos, la descripción del plugin debe
derivarse de `GET /api/agent/config` o de una tool de introspección — no volver a
duplicarse.

**Alcance real de reducir el registry:** `Page.all_types/0` (definida en
`knowledge/page.ex:168`) tiene exactamente 4 consumidores — `Knowledge.page_types/0`
(l.417) y `Knowledge.type_enabled?/2` (l.424), `Workspace.settings_changeset/2` vía
`validate_subset` (`workspace.ex:75`) y el `for` del toggle
(`workspace_settings_live.ex:417`). El de `workspace.ex:75` es el peligroso: valida la
lista **guardada** de `disabled_page_types` contra la lista global, así que un workspace
que tenga deshabilitado `technical`/`idea` deja de validar en cuanto el tipo desaparece
del registry → la migración debe limpiar esas listas (o el `validate_subset` debe
tolerar slugs desconocidos como inofensivos).

El skill `skills/dev/dran-dev-page-types/SKILL.md` documenta el procedimiento y su
auditoría obligatoria de surface (siete puntos) — es la guía que hay que reescribir.

### 2.3 El workspace hoy solo **desactiva** tipos

- `workspaces.disabled_page_types` `varchar(255)[]` (`priv/repo/structure.sql:429`),
  validado con `validate_subset(:disabled_page_types, Dran.Knowledge.Page.all_types())`
  (`lib/dran/workspace.ex:75`) — **validación contra la lista global estática**.
- `enabled_features` jsonb (`structure.sql:432`) con `Workspace.feature_enabled?/2`
  (`lib/dran/workspace.ex:117-126`) — **el precedente que propongo reusar**.
- `Knowledge.page_types/0` (l.421-424) y `type_enabled?/2` (l.431) resuelven
  `all_types() -- disabled`.
- Toggle en dos UIs: `workspace_settings_live.ex:216-230` + `page_types_section/1`
  (l.399-436, id `page-type-#{type}`) y `admin_workspaces_live.ex:163-181` + modal (l.415-445).

**Diez LiveViews/componentes iteran `PageRegistry.types()`** asumiendo que la lista es
global: `layouts.ex` (sidebar + counts, l.201-207 y 353-362), `home_live.ex`
(leyenda `ordered_type_colors`, l.377; `@graph_hidden_types` l.34), `command_palette.ex`
(l.38-42, 251-254), `journey.ex` (hues por tipo, l.131, 189-197), `smart_collection_live.ex`
(filtro por tipo, l.144-155, 282-310), `page_list_components.ex` (tabs por tipo, l.230-244),
`graph_helpers.ex` + `graph_cache.ex`, `admin_workspaces_live.ex`, `search_live.ex`,
`page_components.ex`. **Ese es el trabajo real de D3.**

### 2.4 Rutas: el tipo se resuelve por el path, no por slug

```elixir
# lib/dran_web/router.ex — scope final, wildcard
live "/:workspace_slug/:type", PagesLive, :index
live "/:workspace_slug/:type/:slug", PagesLive, :show
```

`PagesLive` resuelve el tipo desde el path con `PageRegistry.type_from_path/1` (l.279-283,
inverso de `ui.path`). Para tipos custom el `path` no puede derivarse por pluralización
ciega: hay que decidirlo (ver §4.3).

### 2.5 API keys: hoy la key ES un agente

La cadena actual, con evidencia:

```
api_keys.name ──► ApiKey.ensure_actor_for_key_name/1 ──► actors(kind: "agent")
   (api_key.ex:60-71)                                      (actors.ex:70-75)
api_keys.actor_id ──► mapa sintético de auth          (router.ex:232-247)
   └─► actor.owner_user_id ──► resolve_owner_user_id  (auth.ex:148-153)
   └─► actor.name ──► resolve_created_by              (auth.ex:125-132)
```

- `api_keys` tiene `actor_id uuid **NOT NULL**` (`structure.sql:132`).
- `actors` guarda `name`, `kind` (`user|agent|system`), `display_name`, `host` y
  `owner_user_id` (`structure.sql:97-104`; el `owner_user_id` lo añade la migración de
  visibilidad `20260916183343`).
- `Dran.Actors` expone el CRUD completo del agente (`list_managed_actors/0` l.50,
  `create_actor/1` l.70, `update_actor/2` l.80, `delete_actor/1` l.101,
  `attribution_count/1` l.122).
- `SettingsLive` es una sola LiveView con dos tabs: `:account` y `:agents`
  (router l.456-458), y dentro de `:agents` conviven **el CRUD de actores**
  (`create_actor` l.370-394, `edit_actor` l.397, `update_actor` l.424, `delete_actor`
  l.462-500) **y** la gestión de keys (`create_api_key`, `edit_agent_access`,
  `revoke/restore/regenerate/delete_api_key`, l.113-365).
- `requires_env` del plugin (`plugin.yaml`) le dice al usuario:
  *"Dran → Settings → Agents → Create key"*.
- `agent_config_controller.ex` devuelve `actor.id/name/display_name` + workspaces y
  `docs/api.md:84-95` lo documenta como endpoint de agente.
- `ContentVisibility.scope/3` (l.87-96) tiene **dos ramas dedicadas al actor de la key**
  (`%{actor: %Actor{owner_user_id: …}}`) — si la key deja de tener actor, esas ramas
  quedan muertas y la identidad de key pierde su scope.

### 2.7 El inventario de la identidad "agente" (verificado)

La cadena completa key→actor→atribución, con los puntos que se borran y los que se adaptan:

| archivo:línea | Qué hace hoy | Acción |
|---|---|---|
| `lib/dran/accounts/api_key.ex:60-71` | `ensure_actor_for_key_name/1` — **crea el actor al crear la key** | borrar (el núcleo del cambio) |
| `lib/dran/accounts/api_key.ex` (campo) | `belongs_to :actor` | adaptar (nullable → drop) |
| `lib/dran/accounts.ex:353` | llamada a `ensure_actor_for_key_name/1` en `do_create_api_key/2` | borrar |
| `lib/dran/accounts.ex:656-676` | `maybe_own_actor/2` — vínculo user→agent actor (D1) | borrar |
| `lib/dran/accounts.ex:638-654` | `resolve_or_create_user_actor/1` + `actor_id/1` (humanos) | **conservar** |
| `lib/dran/auth.ex:94-99` | `actor_name/1` privado: `actor.name \|\| :key_name` | adaptar → `:agent_name \|\| :key_name` |
| `lib/dran/auth.ex:108-117` | `resolve_owner/1` | **borrar: 0 llamadores** (dead code) |
| `lib/dran/auth.ex:125-134` | `resolve_created_by/1` (deriva de `actor_name`) | adaptar (nueva fuente) |
| `lib/dran/auth.ex:146-155` | `resolve_owner_user_id/1` (lee `actor.owner_user_id`) | adaptar → `:created_by_user_id` |
| `lib/dran/auth.ex:164-177` | `agent_name_from_headers/1` (`X-Hermes-Agent`) | **conservar** (es la nueva fuente de identidad) |
| `lib/dran_web/router.ex:275` | `key_name: key.name` en el mapa sintético | conservar |
| `lib/dran_web/router.ex:272-280` | mapa sintético de la key | **adaptar: inyectar el header aquí** |
| `lib/dran_web/resource_authorization.ex` | shapes `%{access_levels: …}`, `%{contexts: …}`, `is_owner: true` | conservar (la rama de `access_levels` es la que sobrevive) |
| `lib/dran/content_visibility.ex:87-96` | 2 ramas para `%{actor: %Actor{owner_user_id: …}}` de la key | **adaptar**: con actores fuera del camino de las keys, necesita una rama para `created_by_user_id` |
| `lib/dran/actors.ex` (CRUD) | `list_managed_actors/0`, `create_actor/1`, `update_actor/2`, `delete_actor/1`, `attribution_count/1` | borrar los del agente; `ensure_system_actors!/0` se queda |
| `lib/dran/actors/actor.ex` | `@kinds ~w(user agent system)` | **conservar `"agent"`** en `@kinds`: hay filas históricas con ese kind y quitarlo rompería cualquier `cast`; simplemente deja de producirse |
| `lib/dran_web/live/settings_live.ex:367-500` | CRUD de actores (5 handlers) | borrar |
| `lib/dran_web/live/settings_live.ex:796-1080` | `agents_tab/1` | reescribir como `api_keys_tab/1` |
| `lib/dran_web/router.ex:458` | `live "/agents", SettingsLive, :agents` | → `/api-keys`, `:api_keys` |
| `lib/dran_web/controllers/api/agent_config_controller.ex:14,22,32,34` | guarda por `user[:actor]`; devuelve `agent: {id,name,display_name}` | adaptar: guardar por key, exponer `name` + `workspaces` + **tipos del workspace** (§5.3) |
| `docs/api.md:59-60,88-95` | "created_by/updated_by derivados del actor del token"; endpoint de agente | adaptar |
| `hermes_plugin/dran/__init__.py:182-183` | `_headers()` añade `X-Hermes-Agent` | **conservar** (ya es la identidad) |
| `hermes_plugin/dran/plugin.yaml:39`, `config_schema.py:11,37,40,61`, `README.md:23,30,117,123-125` | texto "Settings → Agents" | adaptar a "Settings → API Keys" |

**Punto crítico de diseño [inferido, no verificado en runtime]:** `resolve_created_by/1`
recibe solo el mapa sintético, que **no lleva headers**. El header hay que inyectarlo una
vez en `require_api_token/2` (`router.ex:272-280`), donde ya se calcula por request tras
autenticar — más seguro que resolverlo en cada controller (hoy solo 3 controllers de
escritura lo hacen). El camino web no cambia: sigue con
`resolve_created_by(%{email: email})` (`page_edit.ex:486-491`).

### 2.8 `priv/repo/structure.sql` está desactualizado

Verificado: `grep -c owner_user_id priv/repo/structure.sql` → **0** (le faltan
`owner_user_id` y `agent_name`), `api_key_workspaces.id` **no tiene default** (l.112), y
su `schema_migrations` termina en **`20260913174156`** — no incluye las migraciones
`20260916183343` (visibilidad/ownership) ni `20260916190500` (restore del default).
Cualquier base creada desde este dump requiere migrar. **Regenerar con `mix ecto.dump`
antes de usarlo como fuente**; no es parte del cambio de modelo pero se topa con él.

### 2.9 Datos reales en `dran_dev`

```
page_type | count          page_type |    kind    | count
----------+-------         ----------+------------+-------
 note     |    11          note      | plan       |   2
 concept  |     5          note      | journal    |   2
 technical|     4          note      | project    |   1
 idea     |     4          technical | code/pattern/technical/recipe | 1 c/u
 entity   |     3          idea      | idea(2)/question/hypothesis | 1-2
 food     |     2          knowledge | quote/summary | 1 c/u
 reference|     2          entity    | language/framework/product | 1 c/u
 knowledge|     2          food      | ingredient/recipe | 1 c/u
                          reference | website/paper | 1 c/u
```

Total: 33 páginas. **Los tipos que se eliminan (`technical`, `idea`, `food`, `knowledge`)
suman 12 filas** que hay que reasignar. Los kinds solo aparecen en `note`
(`plan`, `journal`, `project`) — o sea, en el único tipo libre; con kind fuera, esos
valores quedan inertes en el JSONB.

---

## 3. Los tres trabajos, y por qué se ordenan así

Los tres cambios **se tocan** (los tres viven en `PageRegistry` / `Knowledge` /
`SettingsLive`), así que no se pueden paralelizar sin colisiones. El orden es por
dependencia real:

1. **W1 — Modelo de página** (4 tipos + kinds fuera + migración de datos).
   Es la base: W2 necesita el registry reducido para colgarle los tipos custom.
2. **W2 — Tipos por workspace** (configuración + resolución + validación diferida +
   todas las superficies que hoy iteran la lista global).
3. **W3 — API keys** (rename, actores fuera del camino de las keys, atribución por
   header, migración). Es independiente de W1/W2 en el código, pero comparte
   `SettingsLive` con W2 → va después para no colisionar.
4. **W4 — Estandarización de UI + DESIGN.md.**
5. **W5 — Docs, skills, plugin y gate final.**

Detalle de waves, gates y claims: `.riel/contract.md`.

---

## 4. Decisiones de diseño que hay que fijar antes de codificar

### 4.1 Cómo se guardan los tipos custom

**Decisión: columna jsonb `workspace_page_types` en `workspaces`**, no tabla propia.

Argumentos desde el código real:
- `page_type` en `knowledge_pages` es **texto sin FK** (`structure.sql:210` solo tiene
  `tags`; el `page_type` es una columna de texto validada en app) → una tabla propia no
  compra integridad referencial que hoy no exista.
- `enabled_features` jsonb + `Workspace.feature_enabled?/2` (`workspace.ex:117-126`)
  es exactamente el mismo patrón (mapa de configuración por workspace, leído en el
  mismo `%Workspace{}` que ya viaja a todas las superficies). Reusarlo evita un
  `Repo.preload` extra en cada render.
- El formato **lista ordenada de objetos** (no mapa) porque el orden define el orden del
  sidebar y de las tabs de tipo, y `Map.new/1` no preserva inserción (pitfall ya
  documentado en el skill dev de page types).

Forma propuesta:

```json
[{"slug":"book","label":"Book","plural":"Books","icon":"hero-book-open",
  "color":"#A3E635","meta_fields":[{"type":"text","key":"author","label":"Author"}]}]
```

### 4.2 Dónde vive la validación workspace-aware

Hoy `Page.changeset/2` valida `validate_inclusion(:page_type, @page_types)` con la lista
**global** (`lib/dran/knowledge/page.ex:148`), y el changeset no conoce el workspace.

**Decisión:** el changeset deja de validar inclusión estática; la validación se hace en
`Dran.Knowledge.create_page/1` y `update_page/2` contra los **tipos efectivos del
workspace**. Ahí sí hay `workspace_id` (y a menudo el `%Workspace{}` precargado que ya
recibe `list_pages/1` vía la opción `:workspace`, ver `knowledge.ex:206`).

Comportamiento fail-closed: si no se puede resolver el workspace, **rechazar** el write
con un error de changeset, no dejar pasar. Razón: el fail-open del gate de lectura es
aceptable (la autorización ya filtró el acceso), pero un tipo fuera de catálogo
persistido contamina el grafo, el sidebar y el `type_from_path` de forma permanente.

### 4.3 Cómo se deriva el path de un tipo custom

Hoy `PageRegistry.path/1` devuelve `ui.path` o `to_string(type) <> "s"` (l.239-246).
Con tipos custom el plural ciego rompe en slugs irregulares (`knowledge`, `technical`).

**Decisión:** el tipo custom guarda un `path` **explícito y único** en el workspace
(no derivado), y el campo se resuelve por workspace, no globalmente. La unicidad se
valida al guardar la configuración (dos tipos custom no pueden compartir path; un custom
no puede pisar `notes|references|entities|concepts`). El router sigue resolviendo por
path, con el `type_from_path` ahora workspace-aware.

### 4.4 Qué pasa con los 12 rows de los tipos eliminados

Aplicando el criterio del skill dev ("REMOVING a type: migrate its rows to `note`, el
tipo libre, para que su `meta.kind` sobreviva como valor legacy"):
- `technical` (4), `idea` (4), `knowledge` (2), `food` (2) → **`note`**.
- `note` ya es el tipo libre; su `meta.kind` (`plan`, `journal`, `project`) queda inerte
  en el JSONB (no se renderiza ni se filtra).
- El down de la migración restaura por `meta->>'kind'` donde exista; donde no, cae a
  `note` (documentado en el `down`, no inventado).

### 4.5 La nueva cadena de atribución de una API key

```
request ──Authorization: Bearer <key>──► api_keys
   created_by        = header X-Hermes-Agent (auth.ex:164-177) || api_keys.name
   owner_user_id     = api_keys.created_by_user_id            (dueno de la key)
   agent_name        = header X-Hermes-Agent (puede ser nil)
```

`resolve_owner_user_id/1` (auth.ex:148-153) deja de leer `actor.owner_user_id` para la
identidad de key y lee `:created_by_user_id` del mapa sintético (que `router.ex:232-247`
ya inyecta). `get /api/agent/config` se conserva como **auto-descripción de la key**
(es lo que el plugin necesita para validar su workspace); el veredicto de renombrarlo o
mantener la ruta por compatibilidad del plugin está en la auditoría de identidad.

### 4.6 El orden seguro para `actors` / `api_keys.actor_id`

`actor_id` es **NOT NULL** hoy (`structure.sql:132`; lo impone
`20260901062734_create_actors_and_link_identities.exs:76`), así que no se puede soltar de
golpe. **Plan en tres tiempos, cada uno desplegable por separado:**

| Tiempo | Migración | Código | Por qué en ese orden |
|---|---|---|---|
| **M1 — aditivo** | `ALTER COLUMN actor_id DROP NOT NULL`; backfill de actores faltantes (los nombres de `api_keys.name`/`created_by` que no tengan actor) | ninguno | Si el código deja de escribir el `actor_id` antes de que la columna sea nullable, **toda creación de key revienta** con `not_null_violation`. M1 debe estar en producción *antes* de desplegar M2 |
| **M2 — el código** | nada | dejar de escribir `actor_id`; dejar de leerlo (`resolve_created_by/1`, `resolve_owner_user_id/1`); borrar `ensure_actor_for_key_name/1`, `maybe_own_actor/2` y el CRUD de agente; rename de la ruta | M2 no puede ir antes: `valid_api_key?/1` **precarga `actor: []`** (`accounts.ex:564`), así que una key sin actor revienta el preload mientras el código viejo siga vivo |
| **M3 — limpieza** | `DROP INDEX api_keys_actor_id_index` + `DROP CONSTRAINT api_keys_actor_id_fkey` + `DROP COLUMN actor_id`; `mix ecto.dump` para regenerar `structure.sql` | nada | Solo con el árbol verde; el drop antes de M2 deja al código sin la columna que preloada |

`actors` **se queda** (la usan `users.actor_id` y los actores de sistema). Borrar las filas
`kind = "agent"` es una decisión **opcional e independiente** (duda ?03). El `down` de M3 es
inestable por naturaleza: las keys nuevas no tienen actor y el `down` tendría que revivir
actores por nombre (está escrito en el `down`, no oculto).

**Dónde van las migraciones:** M1 y M3 son el mismo par; el repo usa `mix ecto.dump`
(`structure.sql` no es migrations-only), y hay 4 particiones de test
(`dran_test0..3`) que el runner de Ecto migra solo.

### 4.7 La reversibilidad de la migración de tipos (bloqueante de diseño)

`20260913040148_restructure_page_types_by_kind.exs` fue reversible **porque conservaba
`meta.kind`**: el `down` reconstruía el `page_type` original a partir del kind. Al
eliminar kinds, **el `down` deja de poder reconstruir el tipo original**. Tres opciones:

- **(a)** Aceptar migración irreversible documentada (el `down` restaura lo que puede y
  lo deja escrito).
- **(b)** Partir en **dos migraciones**: primero el colapso de tipos *conservando* kind,
  luego el borrado de kind. La primera queda reversible, la segunda no.
- **(c)** Snapshot en `knowledge_pages_type_backup` que se dropea en una migración
  posterior.

Recomendación: **(b)** — da un punto de rollback real (el más probable: "metí tipos de
más en `note`") sin costo permanente de tabla. Decisión del dueño.

### 4.8 Filtros de colecciones guardadas que apuntan a tipos que mueren

Verificado en dev: hay una colección "Cocina" con `filters: %{"type" => "food"}`
(`priv/repo/seeds_demo.exs:571-574`). Sin migración queda huérfana. La migración debe
tocar `collections.filters`: reescribir `type` que apunta a un tipo eliminado → `note`, y
eliminar la clave `kind` de todos los filtros.

### 4.9 `due_date` y la maquinaria de `condition`

`note` tiene `{:date, "due_date", condition: {:kind, "reminder"}}` (`page_registry.ex:310`)
y `technical` tiene `condition: {:kind, "code"}` en `language` (`:335`). Con kind fuera:
`language` muere con su tipo; `due_date` **se queda siempre visible** (o se elimina, si el
dueño prefiere que `note` no tenga ese campo). Y toda la maquinaria de evaluación de
condiciones (`condition_met?/3`, `meta_value/3`, `live_form_value/2` en
`markdown_editor_components.ex:635-694`) **se queda sin usuarios**: hay que decidir si se
borra o se deja inerte para futuras condiciones no-kind. Recomendación: borrarla — dejar
código muerto "por si acaso" es lo que produjo las cláusulas `"project"` muertas.

---

## 5. Superficie de tests que se rompe

**Corrección de baseline (verificada):** el "840 passed" que figura en el ledger
archivado está desactualizado. El conteo real hoy es **757 tests**
(`MIX_TEST_PARTITION=0 mix test --only zzz_none` → "Result: 0 tests, **757 excluded**").
El baseline a usar en W1–W5 es **757**, no 840.
Baseline por archivo, medido en esta sesión:
**`settings_live_test.exs` → 30 passed**; **`page_types_test.exs` + `page_meta_test.exs` +
`page_meta_gettext_test.exs` + `food_page_type_test.exs` → 44 passed** (con avisos
`missing_form_id: :raise` en `settings_live_test.exs:509`).

Clasificación por clase de rotura: **KIND** (por `meta.kind`), **TYPE** (por los 4 tipos
que salen), **AGENTS** (por el rename y el fin del CRUD de actores).

| Archivo | Línea | Clase | Aserción / fixture que rompe |
|---|---|---|---|
| `test/dran/page_types_test.exs` | 9-15 | TYPE | `types() == ~w(note idea knowledge technical entity concept reference food)` |
| `test/dran/page_types_test.exs` | 28 | TYPE | itera los 8 tipos afirmando cada capacidad |
| `test/dran/page_types_test.exs` | 46-47 | TYPE | comentario "ahora sólo 4 tipos" — ya desincronizado con `:28` |
| `test/dran/food_page_type_test.exs` | 86-94 | TYPE | `meta_fields("food")` expone `kind`, `cuisine`, `servings`… |
| `test/dran/food_page_type_test.exs` | 100-111 | TYPE | `create_page(%{"page_type" => "food"})` → `{:error, changeset}` |
| `test/dran/food_page_type_test.exs` | 73-74 | TYPE | `assert PageRegistry.agent_description() =~ "food"` (¡sobre código muerto!) |
| `test/dran/food_page_type_test.exs` | 118-126 | KIND | `PageMeta.changeset` rechaza `kind: "alien"` |
| `test/dran/page_meta_test.exs` | 18,26,35,48,71-75 | KIND | `kind` como dato en props; `%{kind: [_]}` en `errors_on` |
| `test/dran/page_meta_test.exs` | 112-118 | KIND | describe "project note kind" |
| `test/dran/page_meta_gettext_test.exs` | 104-118,136-197,211-228 | KIND | labels/pares de kind por tipo, `note_kinds == nil` |
| `test/dran_web/live/pages_live_test.exs` | 54-79 | KIND | badge por kind, incluye kind desconocido (`"technical"`) |
| `test/dran_web/live/pages_live_test.exs` | 81-149 | TYPE+KIND | navega a `/ideas`, `?kind=idea,question`, fixture `page_type: "idea"` |
| `test/dran_web/live/pages_live_test.exs` | 151-163 | TYPE | `?kind=no-existe` sobre `/ideas` |
| `test/dran_web/live/pages_live_test.exs` | 165-240 | KIND | menú de kind, toggle, `assert_patch …?kind=idea` |
| `test/dran_web/live/pages_live_test.exs` | 241-310 | TYPE+KIND | `name="page[meta][kind]"`, forms por `/ideas`, `/knowledge`, `/technical`, `/food` |
| `test/dran_web/live/pages_live_test.exs` | 321-345 | KIND | autosave con `meta: %{"kind" => "question"}` |
| `test/dran_web/live/settings_live_test.exs` | 227-357 | AGENTS | describe entero de la pestaña de actores (create/edit/delete/kind system) |
| `test/dran_web/live/settings_live_test.exs` | 37-225 | AGENTS | pestaña de agents + create/edit/revoke/copy de keys |
| `test/dran_web/live/instance_shell_test.exs` | 35 | AGENTS | `{"/settings/agents", "topbar-account"}` |
| `test/dran_web/controllers/api/agent_config_controller_test.exs` | 32,80 | AGENTS | helper `agent_conn` con `create_actor(kind: "agent")` |
| `test/dran/content_visibility_migration_test.exs` | 149-172 | AGENTS | `ensure_actor_for_key_name` + `key.actor_id` (backfill) |
| `test/dran/content_visibility_test.exs` | 126-148 | AGENTS | describe "identidad de agente (API key)" |
| `test/dran/memory_visibility_test.exs` | 252-282 | AGENTS | agentes heredan la preferencia del dueño |
| `test/dran/knowledge_test.exs` | 77-147 | TYPE | `disabled_page_types` con `reference`/`entity`, validación `bogus_type` |
| `test/dran/graph_test.exs` | 62,249-257 | KIND | `meta: %{"kind" => "idea"}` |
| `test/dran/props_materializer_test.exs` | 43,121,265 | KIND | `kind: "person"/"idea"` como ruido junto a props |
| `test/dran/props_backfill_test.exs` | 45,69,87,104 | KIND | idem |
| `test/dran/knowledge_props_normalization_test.exs` | 65 | KIND | `meta: %{"kind" => "person"}` |
| `test/dran_web/controllers/home_graph_controller_test.exs` | 40,73 | NO ROMPE | `meta: %{"kind" => "todo"}` es dato; la aserción es sobre `hidden types` |
| `test/dran/jobs_test.exs` | 136,342 | KIND | `report.meta["kind"] == "log"` (tabla `reports`, no `knowledge_pages`) |
| `test/dran/worker/curator_test.exs` | 461 | KIND | idem |
| `test/dran/worker/graph_rag_test.exs` | 227,240,416 | KIND | `meta["kind"]` (`technique`, `answer`) |
| `test/dran/journey_test.exs` | 202 | NO ROMPE | `map_size(colors) == length(PageRegistry.types())` es relativo (4==4); el comentario `:201` dice "8" |

**Recuento verificable:** ~17 tests rompen en duro, ~15 rompen condicionados a la
limpieza (3 kind en lib/migración + 12 de actor-en-key), y el resto son adaptaciones.
El desglose exacto por archivo está en la tabla.

**Pérdida de cobertura que hay que declarar explícitamente:**
1. **Validación de kind en el changeset** (`page_meta_test.exs:70-76`,
   `food_page_type_test.exs:118-126`) — el modelo nuevo no valida `meta.kind` en absoluto,
   así que **no hay puerto**: esa cobertura se retira.
2. **Los 6 tests de kind-UI** (dropdown, filtro single/multi, unknown kinds, menú) — solo
   sobreviven si un **tipo custom** puede tener kinds; si no, se borran (17 → 23 borrados).
   Es la duda ?02, y hay que responderla antes de tocar la UI porque los tests se apoyan
   en `data-testid="kind-filters"` (`pages_live_test.exs:84,238`) y en
   `#page-type-#{type}`.

## 5.1 Superficie `meta.kind`: el inventario real

El borrado de kind toca **~45 sitios** en `lib/`, no los ~25 que estimé al principio.
Los bloques grandes: `page_registry.ex` (admite 15 puntos: `:kinds` ×6, `kind_options/1`,
`kind_label/1`, `kind_labels/0` con ~70 labels, `condition: {:kind,…}` ×2, moduledoc,
bloque gettext), `page_meta.ex` (`field :kind`, `validate_kind/2`, `:kind` en `all_fields/0`,
`note_kinds/0`), `knowledge.ex` (`maybe_filter_kind/2` + la opción `:kind` + docs),
`pages_live.ex` (10 puntos: los 4 events, `valid_kinds/2`, `kind_filters`, el tramo `?kind=`
del back-path), `page_list_components.ex` (el dropdown entero + `kind_options/1` +
`kind_title/2` + `kind_badge_label/1`), `page_components.ex` (el `<select>`, `kind_options_for/1`,
`meta_kind/1`), `smart_collection_live.ex` (7 puntos, incluido `normalize_kind_param/1` y
`format_value("kind",…)`), `markdown_editor_components.ex` (la maquinaria `condition_met?/3`
+ `meta_value/3` + `live_form_value/2`).

**Escritores de `meta.kind` que hay que decidir uno a uno** (no son solo lectores):

| Sitio | Escribe | Decisión |
|---|---|---|
| `lib/dran/worker/curator.ex:328` | `%{"kind" => "log"}` en `knowledge_pages` | quitar (el `report_type: "log"` de la tabla `reports` es el campo real) |
| `lib/dran/worker/graph_rag.ex:524` | `%{"kind" => "answer"}` | quitar (conservar `mode`/`sources`/`worker_session_id`) |
| `lib/dran_web/page_edit.ex:598` | `%{"kind" => "file"}` al subir a un `reference` | quitar (conservar filename/mime/size/sha256) |
| `lib/dran/jobs.ex:373` | `%{kind: "log"}` en la tabla `reports` | adaptar (tabla distinta, `report_type` manda) |

**Dos módulos casi muertos** que el inventario dejó al descubierto:
- `Dran.Knowledge.PageMeta.changeset/3` **no se llama desde ningún sitio de producción**
  (solo desde su propio `@doc` y tests): `validate_kind/2` ya está muerto hoy.
- `Dran.PageRegistry.agent_description/0`, `agent_enum/0`, `agent_meta_description/0`:
  0 consumidores en `lib/` (el único match fuera de su definición es el test
  `food_page_type_test.exs:73-74`).
- `Dran.Auth.resolve_owner/1` (`auth.ex:108-117`): 0 llamadores — solo una mención en un
  comentario de `lib/dran_web/plugs/auth.ex:207`.

## 5.2 Rutas: el tipo inexistente no da 404, da una lista sin filtro

Verificado en `pages_live.ex:425-433` (`page_type_from_params/1` →
`PageTypes.type_from_path/1`): para un path desconocido devuelve `nil` y la lista se
renderiza **sin filtro** (no un 404). Y hay un gate en `pages_live.ex:159`
(`if page_type not in PageTypes.keys() → push_navigate("/")`) que hoy redirige a home.
Con tipos custom, ese gate es **el punto que hay que volver workspace-aware**: si no, un
tipo custom redirige silenciosamente a la portada.

Colisiones de path a respetar (declaradas antes del wildcard en `router.ex:611-634`):
`collections`, `clusters`, `search`, `activity`, `journey`, `graph`, `memory`,
`report`, `letter`, `collection`, `settings`, `api`, `dev`, `login`, `session`, `auth`,
`health`, `docs`, `admin`.

## 5.3 El plugin descubre workspaces, no tipos

`lib/dran_web/controllers/api/agent_config_controller.ex:25-36` devuelve `workspaces` +
`access_levels` y **no expone los tipos**. Con tipos custom, el plugin no tiene forma de
saber qué tipos existen en el workspace donde escribe: `hermes_plugin/dran/__init__.py:984`
y `:1010` llevan la lista de 8 tipos **hardcodeada en Python**, fuera del registry de
Elixir. Consecuencia: los tipos custom son invisibles para el agente hasta que se añadan
al payload de `/api/agent/config` (es el arreglo natural, y además vive en el endpoint que
el plugin ya llama en cada arranque).

---

## 6. UI y DESIGN.md

### 6.1 El DESIGN.md está desalineado de la realidad en lo fundamental

Correcciones verificadas contra el código (cada una con su comando):

| Afirmación de `DESIGN.md` | Realidad verificada | Evidencia |
|---|---|---|
| "Un solo tema: `dark`" (C1/C2, y Custom l.431) | El app corre **`night`** | `root.html.heex:2` → `<html lang="es" data-theme="night">`; `app.css:24` → `themes: night --default;` (commits `0366b01` y `fb2cf8f`) |
| C2: `<html data-theme="dark">` | idem: `night` | `grep data-theme` → `night` |
| Custom l.603: "`root.html.heex` — `data-theme=\"dark\"`" | idem: `night` | mismo grep |

Los tres repos comparten el Commons byte a byte, y **cada uno declara su tema en
Custom** (TokenGate: `dim`; gorim: `dark`; Dran: **`night`**). Así que el tema es
legítimamente propio de Dran — lo que está mal es que el Commons escriba `dark` como
"el tema ÚNICO de la familia" y que Custom repita `dark` en vez de `night`. **Esto es
una corrección documental, no un cambio de tema**: el tema no se toca en este trabajo.

### 6.2 La forma canónica de C5 no la usa nadie

C5 exige `card bg-base-100 border border-base-300 shadow-sm` como única caja.
Verificado: **0 usos** de esa cadena exacta en `lib/dran_web/`. Lo que hay:

- `card bg-base-100 border border-base-300` **sin sombra** ×7 (`home_live.ex:529,576,601,637`,
  `cluster_live.ex:83`, `smart_collection_live.ex:63`, `admin_users_live.ex:239`),
- `shadow-xl` ×2 y `shadow-2xl` ×1 (modales: `admin.ex:48`, `resource_components.ex:65`,
  `dashboard_live.ex:120`),
- `surface-2` ×29 en 12 archivos (la caja propia de D1, que D1 llama literalmente
  "**card estándar**").

O sea: hay **dos** sistemas de caja (`card` del Commons y `surface-2` de Dran) y
**ninguno** usa la forma canónica de C5. Decisión pendiente en W4 (§Dudas ?06).

### 6.3 D6 corregido y D7/D8 escritos en esta sesión — las cifras de D8

D6 (la discordancia del `<.table>`) ya estaba resuelto por el commit `6ac1e56`:
`core_components.ex:380` rinde `table table-sm` y `app.css:556-562` tiene la regla de
hover. Reescrito como "✅ resuelta".

Lo que **corregí** de mi propia primera pasada de D8, al verificar con grep:

- Dije "`<.header>` se usa 1 vez (`activity_live.ex:71`)". **Falso**: `grep -rn "<\.header[^_a-zA-Z]" lib test assets` → **0 usos**. Lo de `activity_live.ex:71` es
  `<.header_section>`, un `defp` **local** (`activity_live.ex:94`), no el componente
  del Commons. El `<.header>` de `core_components.ex:332-346` es **código muerto**
  (0 consumidores) y además usa `text-lg font-semibold`, no la escala propia de Dran.
- Cifras reales medidas: **34** `h1` en total, **24** con `text-title`, 9 con
  `text-2xl/3xl font-bold`; `surface-2` ×29 en 12 archivos; `card bg-base-100` ×11;
  `btn-outline` ×3; `btn-soft` ×1; `data-testid` ×24 conviviendo con 91 `id="`.

### 6.4 D2/D3 y desviaciones menores

- **D2** enumera las "tres opciones de instancia" y el shell sin sidebar; mencionaba
  `/settings/agents` — pasa a `/settings/api-keys` (ya actualizado).
- **D3** documenta `<.admin_section>` en el `@doc` de `admin.ex:71` mientras la función
  real es `section/1` (`admin.ex:82`): 11 call sites usan `<.section>` y 1 usa
  `<.admin_section>` — dentro de su propio `@doc`. El doc miente.
- **D3** está incompleta: faltan `page_components.ex` (`backlinks_section/1:361`,
  `tabs_bar/1:453`, `empty_state/1:502`, `graph_3d/1:547`, `page_attributes/1:815`,
  `page_edit_form/1:883`, `page_new_form/1:938`) y `markdown_editor_components.ex:204`.
- `search_live.ex:509-538` tiene cláusulas **muertas** (`"project"`) y **duplicadas**
  (`concept` y `knowledge` comparten `bg-warning/10`).
- `graph_3d.js:510-515` duplica los paths del registry en JS con fallback `${type}s`:
  un tipo custom genera URL rota silenciosa.
- `priv/repo/structure.sql` **está desactualizado** (ver §2.6): no tiene `owner_user_id`
  ni `agent_name`, `api_key_workspaces.id` no tiene default, y su `schema_migrations`
  termina en `20260913174156`. Hay que regenerarlo con `mix ecto.dump` antes de usar el
  dump como fuente.

---

## 7. Riesgos y trampas conocidas

1. **`kind_label/1` es `Map.fetch!`** (`page_registry.ex:450`). Borrar `kind_labels/0`
   sin borrar todos los llamadores revienta la lista entera con un 500.
2. **`validate_subset(:disabled_page_types, Page.all_types())`** (`workspace.ex:75`)
   contra la lista global: si un workspace ya tiene deshabilitado un tipo que se elimina
   (`technical`, `idea`…), la lista guardada deja de validar → hay que limpiarla en la
   migración o el settings form falla al guardar. **Los consumidores de `all_types/0` son
   solo 4** (`knowledge.ex:417`, `:424`, `workspace.ex:75`, `workspace_settings_live.ex:417`),
   así que el radio de impacto de reducir el registry está acotado y verificado.
3. **Cláusulas mueren silenciosas**: `type_chip_bg("project")` sobrevive a la eliminación
   del tipo `project` sin fallar; el mismo patrón se repetirá con los 4 tipos que salen.
4. **El router resuelve por path**: `/ideas`, `/knowledge`, `/technical`, `/food` dejan de
   resolver. Los tests navegan por esos paths (`pages_live_test.exs:82`), y los bookmarks
   de usuario también. Hay que decidir si se añade un redirect 301 de los paths muertos a
   `/notes` (recomendado) o se acepta el 404.
5. **`graph_3d.js`** tiene el mapa `typePaths` + fallback `${type}s`: un tipo custom sin
   entrada en el mapa cae al fallback y genera una URL rota silenciosa.
6. **El plugin Hermes hardcodea la lista de tipos** en dos descripciones de tools
   (`__init__.py` ~983, ~1014) y su `plugin.yaml` apunta al usuario a "Settings → Agents".
7. **El ledger `.riel/` está en `.gitignore`** y no debe entrar en ningún commit.

---

## 8. Entregables

| Entregable | Ruta |
|---|---|
| Este análisis | `docs/page-model-simplification.md` |
| Plan ejecutable (waves, gates, claims) | `.riel/contract.md` |
| Estándar visual actualizado | `DESIGN.md` (Custom, D1–D9) |
| Estado verificado de la ejecución | `.riel/ledger.md` |
