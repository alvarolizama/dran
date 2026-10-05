defmodule DranWeb.ServicesLive do
  @moduledoc """
  La sección de SERVICIOS (`/services`): lo que la instancia expone y lo que
  ESTE lector tiene conectado, con su estado real y la identidad del proveedor.

  Tres reglas que se ven en cada línea de esta superficie:

  * **El estado se lee del servidor, siempre.** Se consulta al montar y después
    de cada acción; nunca se guarda en el socket como verdad. La vuelta del
    consentimiento aterriza en `/services/callback`, que no lee ni un parámetro
    — los query params de una vuelta OAuth son input, no prueba de propiedad.
  * **La lectura es del lector.** `Dran.Services.list_services/1` filtra por su
    identidad: las conexiones de otro no existen en esta pantalla.
  * **Ningún id crudo del vendor se imprime.** Se ve el nombre del servicio, su
    estado de ciclo de vida y la identidad real del proveedor (`displayName`);
    los `trs_…`/`ca_…`/`ac_…` se quedan en el borde.

  El vocabulario es conectar | reconectar | desconectar — no hay pausa — y
  desconectar BORRA con revocación upstream irreversible: la advertencia va
  ANTES, en el diálogo.
  """

  use DranWeb, :live_view

  alias Dran.Services
  alias DranWeb.Plugs.Auth

  @impl true
  def mount(params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session, params)

    socket =
      assign(socket,
        active_nav: "services",
        page_title: gettext("Services"),
        services: [],
        configured: Services.enabled?(),
        selected: nil,
        load_error: nil
      )

    {:ok, load_services(socket)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:selected, params["toolkit"])
      |> put_returned_flash(params["returned"])

    {:noreply, socket}
  end

  # ── Acciones ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("connect", %{"toolkit" => toolkit}, socket) do
    case Services.connect_link(socket.assigns.user, toolkit) do
      {:ok, %{redirect_url: url}} ->
        # El consentimiento lo hospeda el proveedor: el navegador va para allá
        # y vuelve por `/services/callback`. La vuelta NO se cree — el estado se
        # vuelve a consultar al montar.
        {:noreply, redirect(socket, external: url)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error(reason))}
    end
  end

  def handle_event("disconnect", %{"toolkit" => toolkit}, socket) do
    case Services.disconnect(socket.assigns.user, toolkit) do
      {:ok, %{disconnected: true}} ->
        socket
        |> put_flash(
          :info,
          gettext("Service disconnected. The provider revocation is already in flight.")
        )
        |> assign(:selected, nil)
        |> load_services()
        |> then(&{:noreply, &1})

      {:ok, %{disconnected: false}} ->
        # Nada que borrar: o no había conexión, o la conexión no es de este
        # lector (la lectura la filtró y no la vio).
        socket
        |> put_flash(:info, gettext("There was no connection to disconnect."))
        |> load_services()
        |> then(&{:noreply, &1})

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error(reason))}
    end
  end

  def handle_event("close_manage", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/services")}
  end

  # ── Datos ─────────────────────────────────────────────────────────────────

  defp load_services(socket) do
    case Services.list_services(socket.assigns.user) do
      {:ok, services} ->
        assign(socket, services: services, configured: true, load_error: nil)

      {:error, :not_configured} ->
        assign(socket, services: [], configured: false, load_error: nil)

      {:error, reason} ->
        assign(socket, services: [], load_error: action_error(reason))
    end
  end

  defp put_returned_flash(socket, nil), do: socket

  defp put_returned_flash(socket, _returned) do
    put_flash(
      socket,
      :info,
      gettext("Checking the connection with the provider…")
    )
  end

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      user={@user}
      workspace_slug={@workspace_slug}
      active_nav={@active_nav}
    >
      <div class="p-6 overflow-y-auto w-full">
        <.resource_list_header title={gettext("Services")} />

        <p class="text-caption -mt-2 mb-6">
          {gettext(
            "Connect your apps so your agents can use them. A connection belongs to you: only you can run against it, and disconnecting revokes it at the provider."
          )}
        </p>

        <div
          :if={!@configured}
          id="services-not-configured"
          data-testid="services-not-configured"
          class="alert alert-info mb-6"
        >
          <.icon name="hero-information-circle" class="size-5 shrink-0" />
          <div class="text-sm">
            <p>{gettext("This instance has no services integration configured.")}</p>
            <.link :if={@is_owner} navigate={~p"/admin/system"} class="link link-hover font-medium">
              {gettext("Check the integration state")}
            </.link>
          </div>
        </div>

        <div :if={@load_error} id="services-error" class="alert alert-error mb-6" role="alert">
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
          <span class="text-sm">{@load_error}</span>
        </div>

        <div :if={@services != []} id="services-list" class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.resource_card
            :for={service <- @services}
            id={"service-card-#{service.toolkit}"}
            testid={"service-#{service.toolkit}"}
            icon={service_icon(service.toolkit)}
            title={service.name}
            href={~p"/services?toolkit=#{service.toolkit}"}
            badge={service_status_label(service)}
            badge_class={service_status_class(service)}
            summary={service.description}
            meta={service.identity}
          />
        </div>

        <.resource_empty_state
          :if={@services == [] && @configured}
          icon="hero-squares-plus"
          title={gettext("No services exposed")}
          description={
            gettext(
              "The instance owner decides which services are available. Once one is exposed, you can connect it here."
            )
          }
          cta={gettext("Settings")}
          navigate={~p"/admin/instance"}
        />

        <.manage_service
          :if={@selected}
          service={Enum.find(@services, &(&1.toolkit == @selected))}
          toolkit={@selected}
        />
      </div>
    </Layouts.app>
    """
  end

  # El diálogo de UN servicio: estado, identidad del proveedor y las acciones
  # del vocabulario (conectar | reconectar | desconectar). Abierto por estado de
  # URL (`?toolkit=<slug>`), cerrado con `close_manage`.
  attr :service, :map, default: nil
  attr :toolkit, :string, required: true

  defp manage_service(assigns) do
    ~H"""
    <.modal
      :if={@service}
      id="service-manage-modal"
      title={@service.name}
      on_close="close_manage"
      max_w="max-w-xl"
    >
      <div class="space-y-4">
        <div class="flex items-center justify-between rounded-lg surface-2 px-3 py-2">
          <span class="text-sm text-base-content/70">{gettext("Status")}</span>
          <span class={[
            "text-xs font-medium px-2 py-0.5 rounded-full",
            service_status_class(@service)
          ]}>
            {service_status_label(@service)}
          </span>
        </div>

        <p :if={@service.description} class="text-sm text-base-content/60">
          {@service.description}
        </p>

        <div :if={@service.identity} class="text-sm">
          <span class="text-base-content/60">{gettext("Connected as")}</span>
          <span class="font-medium break-all">{@service.identity}</span>
        </div>

        <p class="text-xs text-base-content/50">{status_hint(@service)}</p>

        <div class="flex flex-wrap gap-2 pt-2">
          <button
            :if={!@service.connected}
            type="button"
            id={"connect-#{@service.toolkit}"}
            phx-click="connect"
            phx-value-toolkit={@service.toolkit}
            class="btn btn-primary btn-sm transition hover:scale-[1.02] active:scale-95"
          >
            <.icon name="hero-link" class="size-4" /> {gettext("Connect")}
          </button>

          <button
            :if={@service.connected}
            type="button"
            id={"reconnect-#{@service.toolkit}"}
            phx-click="connect"
            phx-value-toolkit={@service.toolkit}
            class="btn btn-outline btn-sm transition hover:scale-[1.02] active:scale-95"
          >
            <.icon name="hero-arrow-path" class="size-4" /> {gettext("Reconnect")}
          </button>

          <button
            :if={@service.connected}
            type="button"
            id={"disconnect-#{@service.toolkit}"}
            phx-click="disconnect"
            phx-value-toolkit={@service.toolkit}
            data-confirm={
              gettext(
                "Disconnect %{service}? The provider revokes the access and it cannot be undone — you will have to authorize it again.",
                service: @service.name
              )
            }
            class="btn btn-ghost btn-sm text-error transition hover:scale-[1.02] active:scale-95"
          >
            <.icon name="hero-trash" class="size-4" /> {gettext("Disconnect")}
          </button>
        </div>

        <p class="text-[11px] text-base-content/40">
          {gettext(
            "The authorization link is valid for 10 minutes: if it expires, ask for a new one — an old link is never retried."
          )}
        </p>
      </div>
    </.modal>
    """
  end

  # ── Presentación ──────────────────────────────────────────────────────────

  defp service_status_label(%{status: nil}), do: gettext("Not connected")
  defp service_status_label(%{status: "ACTIVE"}), do: gettext("Connected")
  defp service_status_label(%{status: "INITIATED"}), do: gettext("Pending authorization")
  defp service_status_label(%{status: "INITIALIZING"}), do: gettext("Pending authorization")
  defp service_status_label(%{status: "EXPIRED"}), do: gettext("Expired")
  defp service_status_label(%{status: "INACTIVE"}), do: gettext("Disabled")
  defp service_status_label(%{status: status}), do: status

  defp service_status_class(%{status: "ACTIVE"}), do: "bg-success/15 text-success"
  defp service_status_class(%{status: "INITIATED"}), do: "bg-warning/15 text-warning"
  defp service_status_class(%{status: "INITIALIZING"}), do: "bg-warning/15 text-warning"
  defp service_status_class(%{status: "EXPIRED"}), do: "bg-error/15 text-error"
  defp service_status_class(%{status: "INACTIVE"}), do: "bg-base-300 text-base-content/60"
  defp service_status_class(_service), do: "bg-base-300 text-base-content/60"

  defp status_hint(%{status: "ACTIVE"}) do
    gettext("Your agents can use this service now.")
  end

  defp status_hint(%{status: "EXPIRED"}) do
    gettext("The authorization expired. Reconnect to issue a new link.")
  end

  defp status_hint(%{status: "INACTIVE"}) do
    gettext("The connection is disabled at the provider, so it cannot run tools.")
  end

  defp status_hint(%{status: status}) when status in ["INITIATED", "INITIALIZING"] do
    gettext("The authorization was started but not completed yet.")
  end

  defp status_hint(_service) do
    gettext("Connecting sends you to the provider to authorize access.")
  end

  # El icono es decoración por toolkit conocido; uno genérico para el resto.
  defp service_icon("gmail"), do: "hero-envelope"
  defp service_icon("googlecalendar"), do: "hero-calendar"
  defp service_icon("slack"), do: "hero-chat-bubble-left-right"
  defp service_icon("github"), do: "hero-code-bracket"
  defp service_icon("googledrive"), do: "hero-folder"
  defp service_icon("notion"), do: "hero-document-text"
  defp service_icon(_toolkit), do: "hero-squares-plus"

  defp action_error(:not_configured),
    do: gettext("This instance has no services integration configured.")

  defp action_error(:not_allowed),
    do: gettext("This service is not exposed by the instance.")

  defp action_error({:composio, _status, _body}),
    do: gettext("The services provider refused the request. Try again in a moment.")

  defp action_error(_reason),
    do: gettext("Something went wrong talking to the services provider.")
end
