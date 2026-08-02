# Checklist de validación — nuevo `graph_3d.js` con `3d-force-graph`

**Contexto revisado en el código actual** (`assets/js/hooks/graph_3d.js`, `app.js`, `graph_live.ex`, `graph_helpers.ex`, `graph_events.ex`):

- El hook actual es **three.js custom** (esferas + layout esférico + OrbitControls). El nuevo será **drop-in replacement con `3d-force-graph`**.
- GraphLive (`.render`) inyecta `data-graph={graph_json(assigns)}`. Formato servidor:
  - `nodes`: `{id, slug, label, type, color}` (color = hex ya resuelto server-side).
  - `edges`: `{source_id, target_id, color}`.
- Servidor espera evento `node_click` con `%{"slug" => slug}` → `push_navigate("/graph/:slug")`.
- Inline subgraphs (`page_graph`) hoy usan `GraphPanZoom` (SVG + `phx-click="node_click"` + `phx-value-slug`). El toggle 2D/3D es el punto de integración para Graph3D en tabs.
- No hay toggle 2D/3D implementado en GraphLive aún (es el plan); el checklist asume que se montará/desmontará el hook.

---

## 1. Memory leaks en `destroyed()`

- [ ] `cancelAnimationFrame(this.animationId)` cancela el bucle del renderer (3d-force-graph devuelve un `control`; parar con `graph.pauseAnimation()` o `cancelAnimationFrame`).
- [ ] `window.removeEventListener("resize", handler)` — el resize handler debe ser la misma referencia que se registró (nunca una arrow inline nueva).
- [ ] `renderer.dispose()` llamado y `canvas`/`domElement` removido del DOM (`parentNode.removeChild`).
- [ ] **Geometry/Material dispose en rebuild:** al re-pintar en `updated()`, se debe `dispose()` de toda geometría y material anterior ANTES de crear los nuevos (evita perder memoria en WebGL). En el nuevo 3d-force-graph, `graph.graphData({nodes:[], links:[]})` para vaciar — verificar que libera buffers GPU.
- [ ] `controls.dispose()` (OrbitControls) y null de referencias.
- [ ] **Listener de click:** si el nuevo hook añade listeners manuales al domElement (además del manejador interno de 3d-force-graph), deben desconectarse, o se acumularán en cada mount/unmount.
- [ ] Probar **ciclo repetido** mount→toggle a 2D→toggle a 3D→unmount **≥20 veces** sin crecer memoria de página (DevTools → Performance memory / `window.gc()` con flag). Registrar heap antes/después.
- [ ] Verificar en **Performance monitor** (browser) que el `GPU process`/`memory` vuelve a nivel inicial tras unmount (los buffers WebGL suelen retenerse si no se dispose).
- [ ] Al teclear `node_drag`/re-layout: sin listeners duplicados ni estructuras `userData` huérfanas.

## 2. `pushEvent("node_click")` igual que antes

- [ ] **Payload exacto:** el evento se dispara con `{slug: <slug>}` — el servidor espera `%{"slug" => slug}` en `GraphLive.handle_event("node_click", ...)` y en `GraphEvents.node_click/2`. No cambiar la clave ni añadir campos que rompan el pattern match.
- [ ] Click en nodo con slug → navega a `/graph/:slug` (regresión manual en GraphLive :index).
- [ ] **Nodo sin slug:** no debe lanzar excepción; debe ignorar el click (igual que el actual `if (node.slug)`).
- [ ] Click en **link** (edge) no debe disparar `node_click` (el nuevo 3d-force-graph usa `onNodeClick` separado de `onLinkClick` — no enlazar el de link al de nodo).
- [ ] **Drag vs click:** si se habilitó arrastre de nodos, asegurar que un drag no dispare accidentalmente `node_click` (umbral de movimiento; coherente con 2D que distingue drag de click).
- [ ] Verificar que `pushEvent` llega al socket LiveView correcto cuando el hook está dentro de un **tab inline** (mismo hook id dominio) — el evento `node_click` debe resolverse en el LiveView de la página, no en `/graph`.
- [ ] Sin dobles disparos (evento una única vez por click).

## 3. Parseo de `data-graph` (JSON attribute)

- [ ] El hook lee `this.el.getAttribute("data-graph")` y hace `JSON.parse`.
- [ ] **JSON anidado correcto:** el attribute viene escapado como HTML (comillas dobles). Ejemplo real inyectado por LiveView debe parsear sin error (probar con un graph real con `'` y `"` en labels/títulos).
- [ ] **Campos mínimos:** node requiere `{id, slug, label, type, color}`; edge requiere `{source_id, target_id, color}`. El nuevo hook debe consumir **estos campos**, sin renombrar (`slug` no `title`, `source_id`/`target_id` no `source`/`target`).
- [ ] **Edge references a nodos inexistentes:** `3d-force-graph` lanza error si un link apunta a un id que no existe en nodes. El server ya filtra (ambos endpoints visibles), pero **validar grafo vacío** (nodes=[] con edges=[]) y edge huérfano no crashea.
- [ ] **Error handling:** JSON inválido → `try/catch` con `console.error`, devolver null, NO colapsar el hook (comportamiento idéntico al actual).
- [ ] **`updated()` re-parse:** en cada callback `updated()`, re-leer el attribute y reconstruir. Si el nuevo code pone `data-graph` en un nodo distinto o en `phx-*`, validar que el attribute sigue disponible en `this.el`.
- [ ] **Precedencia id:** `node.id` numérico o string — `3d-force-graph` usa `id` como clave; asegurar consistencia (el server manda id, no slug, como id del nodo).

## 4. Resize handler

- [ ] Cambiar el tamaño de la ventana (y del contenedor de la página) actualiza **camera aspect + projection matrix + renderer size** (o `graph.width()`/`graph.height()` en 3d-force-graph).
- [ ] Redimensionar NO re-imprime el layout desde cero (pérdida de zoom/posición de cámara).
- [ ] `clientWidth/clientHeight` leído del contenedor (no de `window.innerWidth/innerHeight`) para respetar layout del sidebar.
- [ ] **Tab de pestaña escondida (`display:none`):** cuando el graph 3D vive en un tab inline y el tab se oculta/muestra, el `clientWidth` es 0 en mount → fijar tamaño correcto al hacerse visible (como hace GraphPanZoom con IntersectionObserver). Si el nuevo hook no reposiciona al mostrarse, se ve cortado/0×0.
- [ ] Sin errores cuando el contenedor es 0×0 (guard).
- [ ] Resize dentro del mismo hook no registra listeners duplicados (una sola vez en mount, una sola remoción en destroy).

## 5. Toggle 2D/3D en GraphLive (y tabs inline)

> No existe hoy un toggle en GraphLive; este punto valida que el nuevo hook se integra sin romper el cambio de vista.

- [ ] **Toggle 2D→3D:** al activar 3D, el hook monta renderer y dibuja; al volver a 2D, `destroyed()` se ejecuta limpio (sin residuo de canvas/WebGL).
- [ ] **Toggle repetido en ambos sentidos** sin pérdida funcional ni doble renderer en el DOM (verificar que no quedan `<canvas>` huérfanos tras varios toggles).
- [ ] **GraphLive :index** sigue renderizando sin toggle: el hook 3D monta directo en `div#graph-3d` correctamente.
- [ ] **Inline tabs** (`detail-tab-graph` / slots `:graph`): al montar dentro de un panel oculto → ver punto 4. Al cambiar de pestaña a Content, el hook 3D hace unmount → limpieza correcta; al volver, remount re-parsea data.
- [ ] **`updated()` en toggle:** si LiveView re-renderiza el graph (filter de tipos, borrado de página) mientras el toggle está en 3D, el hook re-sincroniza data (mismos nodos/edges, nueva posición).
- [ ] No romper `switch_tab` / `toggle_type` en el server (los events siguen funcionando con el 3D activo o inactivo).
- [ ] Coexistencia `GraphPanZoom` (2D SVG) e `Graph3D` (3D): ambos hooks no luchan por el mismo DOM (no deben estar montados simultáneamente sobre el mismo elemento).

## 6. Colores por tipo

- [ ] **Paleta server-side respeta:** node.color y edge.color ya llegan resueltos (`type_colors`, `edge_colors`). El nuevo hook debe aplicar `parseColor(color)` tal cual, sin re-mapear ni olvidar `node.color`.
- [ ] **Fallback** para color ausente → `#94A3B8` (gris), idéntico al actual, para tipos nuevos sin color definido.
- [ ] **Toggle de tipos (`toggle_type`):** al ocultar un tipo, los nodos de ese tipo deben **desaparecer** y sus edges también (el server ya filtra; el re-parse en `updated()` debe reflejar los nodos visibles). Al reactivarlo, reaparecen con su color.
- [ ] Comparación **visual lado a lado 2D vs 3D**: el mismo tipo debe tener el mismo color en ambas vistas (misma fuente `GraphHelpers.type_colors()`).
- [ ] Manejo de `oklch()/color-mix()`: si se pasara un color no-hex (CSS var), validar que se resolve (el actual usa `readThemeColor`). Si el nuevo cae en `parseColor` solo, los formatos CSS complejos deben transformarse antes de `THREE.Color`.
- [ ] Sin estados de color perdidos al re-build en `updated()` (emissive/tint coherente con el color base).

## 7. Performance con 100+ nodos

- [ ] **Carga:** graph con **≥100 nodos y ≥200 edges** (forzar el caso `:index` de un brain grande) monta sin congelar el hilo principal (> ~1–2s para primer paint 3D).
- [ ] **FPS durante interacción:** mantener **≥45–50 fps** mientras se rota/mueve con OrbitControls (no `force-directed` re-calculando cada frame de forma costosa → `forceSimulation` warmup + `pauseSimulation()` tras el layout inicial).
- [ ] **`updated()`/re-render:** re-pintar 100+ nodos no causa lag perceptible; idealmente 3d-force-graph diff-merge los datos en vez de recrear todos los meshes.
- [ ] **Sprite/labels:** el actual crea un canvas por label — con 100+ nodos validar memoria de texturas. Si el nuevo 3d-force-graph genera `nodeThreeObject` con labels/etiquetas, confirmar que no degrada FPS (lazy/en oscuras).
- [ ] **resize en grafos grandes** no bloquea (control de `setSize` barato).
- [ ] Scroll/zoom fluido sin jank del layout forzado.
- [ ] Desmontar el grafo grande no deja el tab del browser lento tras 20 toggles (memory del punto 1).

---

## Notas / riesgos señalados en la revisión

1. **Contrato `source_id`/`target_id` — crítico:** 3d-force-graph usa `source`/`target` para links en `graphData()`. El nuevo hook debe **traducir** `source_id`→`source`, `target_id`→`target` (o guardarlos bajo `__data`), o los links no se dibujan. Validación explícita recomendada (punto 3/7).
2. **`id` como identity:** asegurar que `node.id` (numérico del server) es tratado como key de nodo en 3d-force-graph (acepta number), y que `onNodeClick` devuelve el objeto con `.slug` accesible.
3. **El server ya filtra por visibilidad** (punto 6): el hook no debe re-filtrar, solo render lo que recibe.
4. **No hay toggle implementado aún** — si el nuevo work se adhiere solo a GraphLive fijo, el punto 5 aplica a la eventual integración de toggle; si lo requieres en inline tabs, debe respetar el patrón `display:none` de `page_detail`.

---

## Ejecución de validación sugerida

1. `mix compile` + `npm` build (`assets/build`) para que el nuevo hook quede bundlado en `app.js`.
2. Crear/editar páginas para poblar **>100 nodos** o usar las fixture del seed.
3. Validación manual en `/graph` (index + `/graph/:slug`) y en un tab inline de una página.
4. Memory: DevTools → Memory → "Take heap snapshot" antes/después de 20 toggles 2D↔3D.
5. Performance: `Performance panel` grabación 10s durante interacción (FPS, JS timings, GPU memory).
6. Regresión en `mix test test/dran_web/live/graph_live_test.exs` y tests de pages (eventos `node_click`/`switch_tab` server-side).
