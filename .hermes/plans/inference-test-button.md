# Plan: Botón de test de inference API en Settings

## Contexto

El error del buscador (`dran_search` con queries largas) viene de que la inference
API está configurada en prod (URL + API key presentes) pero el host no responde
→ `econnrefused`. El fix de fallback a FTS ya está hecho, pero no hay forma de
saber desde la UI si el inference server está alzado o caído. El `status_badge`
actual solo muestra si la API está **configurada** (URL no nil), no si realmente
**responde**.

## Objetivo

Botón "Probar conexión" en la sección "Inference API" de `/settings` que haga
un ping real al server y muestre el resultado (OK / error) con detalles por modelo.

## Diseño

### UX

En la sección "Inference API" → card row "Status", reemplazar el badge estático
por un badge dinámico + botón "Probar":

```
┌─────────────────────────────────────────────────────┐
│ Inference API                                        │
│                                                      │
│ Status     [● Responde]  [Probar conexión]           │
│ API URL    http://...                                │
│ API Key    ••••••••                                   │
│ ...                                                  │
└─────────────────────────────────────────────────────┘
```

Estados del test:
- **Idle**: badge muestra "Configurada" (azul) + botón "Probar conexión"
- **Testing**: botón muestra spinner + "Probando..." (deshabilitado)
- **OK**: badge verde "● Responde" + texto "Latencia: 234ms · Modelos: 12"
- **Error**: badge rojo "● Sin conexión" + texto del error ("Connection refused")

### Implementación

#### 1. Backend: `Dran.Inference.Client.ping/0`

Nuevo function en `lib/dran/inference/client.ex`:

```elixir
@spec ping() :: {:ok, %{latency_ms: pos_integer(), models: non_neg_integer()}} | {:error, term()}
def ping do
  case Config.enabled?() do
    false -> {:error, :not_configured}
    true ->
      start = System.monotonic_time(:millisecond)
      case request(:get, "/models") do
        {:ok, body} ->
          latency = System.monotonic_time(:millisecond) - start
          count = length(body["data"] || [])
          {:ok, %{latency_ms: latency, models: count}}
        {:error, reason} -> {:error, reason}
      end
  end
end
```

Usa `GET /models` (endpoint estándar OpenAI-compatible) como health check.
Un solo request nos dice: server alzado, API key válida, y cuántos modelos hay.

#### 2. LiveView: evento `test_inference`

En `settings_live.ex`, agregar `handle_event("test_inference", ...)`:

```elixir
@impl true
def handle_event("test_inference", _params, socket) do
  # Hacer el ping asíncrono para no bloquear el LiveView
  pid = self()
  Task.start(fn ->
    result = Client.ping()
    send(pid, {:inference_test_result, result})
  end)

  {:noreply, assign(socket, inference_test: :testing)}
end
```

Y un `handle_info` para recibir el resultado:

```elixir
@impl true
def handle_info({:inference_test_result, result}, socket) do
  {:noreply, assign(socket, inference_test: result)}
end
```

Init en mount: `assign(socket, inference_test: nil)`.

#### 3. Template: badge + botón

Reemplazar el `<.status_badge active={Config.enabled?()} />` estático en la
row de "Status" por un componente dinámico que reaccione a `@inference_test`:

```heex
<.config_row label={gettext("Status")} ...>
  <.inference_status_badge test={@inference_test} configured={Config.enabled?()} />
  <button
    phx-click="test_inference"
    disabled={@inference_test == :testing}
    class="btn btn-xs btn-ghost gap-2"
  >
    <.icon name="hero-bolt" class="size-4" />
    <%= if @inference_test == :testing, do: gettext("Probando..."), else: gettext("Probar conexión") %>
  </button>
</.config_row>
```

Componente `inference_status_badge`:

```elixir
attr :test, :any, default: nil
attr :configured, :boolean

def inference_status_badge(assigns) do
  ~H"""
  <div class="flex items-center gap-2">
    <%= cond do %>
      <% @test == :testing -> %>
        <span class="loading loading-dots loading-xs text-info"></span>
        <span class="text-info text-sm">{gettext("Probando...")}</span>
      <% match?({:ok, _}, @test) -> %>
        <% {:ok, r} = @test %>
        <span class="badge badge-success badge-sm gap-1">
          <.icon name="hero-check-circle" class="size-3" />
          {gettext("Responde")}
        </span>
        <span class="text-xs text-base-content/50">
          {r.latency_ms}ms · {r.models} {gettext("modelos")}
        </span>
      <% match?({:error, _}, @test) -> %>
        <% {:error, reason} = @test %>
        <span class="badge badge-error badge-sm gap-1">
          <.icon name="hero-x-circle" class="size-3" />
          {gettext("Sin conexión")}
        </span>
        <span class="text-xs text-error/70">
          {format_error(reason)}
        </span>
      <% @configured -> %>
        <span class="badge badge-info badge-sm gap-1">
          <.icon name="hero-server" class="size-3" />
          {gettext("Configurada")}
        </span>
      <% true -> %>
        <span class="badge badge-ghost badge-sm gap-1">
          <.icon name="hero-x-mark" class="size-3" />
          {gettext("No configurada")}
        </span>
    <% end %>
  </div>
  """
end
```

#### 4. Tests

- `test_inference_ping/1` en `test/dran/inference/client_test.exs` (o nuevo)
- `settings_live_test.exs`: verificar que el botón existe y responde al click
  (mock o stub del ping)

## Archivos a tocar

| Archivo | Cambio |
|---------|--------|
| `lib/dran/inference/client.ex` | Agregar `ping/0` |
| `lib/dran_web/live/settings_live.ex` | Evento `test_inference`, `handle_info`, componente `inference_status_badge`, init assign |
| `test/dran_web/live/settings_live_test.exs` | Test del botón |

## Lo que NO hacer

- No agregar un test individual por modelo (chat, embed, rerank) — el `GET /models` es suficiente health check. Si quieres test por modelo, es otra feature.
- No hacer polling automático — solo on-demand cuando el user clickea.
- No guardar el resultado en DB — es state efímero del LiveView.
