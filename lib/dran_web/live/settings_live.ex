defmodule DranWeb.SettingsLive do
  @moduledoc """
  Settings page for the logged-in user's account.

  After the F3 /admin split, each user manages only their own profile, password,
  language, Google link and their ONE API credential (`users.api_token`) here.
  Instance-level configuration (users, workspaces, models, system info, jobs)
  lives in the owner-only `/admin/*` LiveViews.

  ## W3 — una sola credencial

  The per-agent API key system is gone: the credential is the account's
  `api_token`, shown (copy/regenerate) in the Account tab. There is no
  `/settings/api-keys` tab and no key CRUD.
  """

  use DranWeb, :live_view

  alias DranWeb.Plugs.Auth

  @impl true
  def mount(params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    user = session_user(session)

    socket =
      socket
      |> assign(
        active_nav: "settings",
        page_title: gettext("Settings"),
        workspace_slug: nil,
        current_user_struct: user
      )
      |> assign(
        profile_form: to_form(Dran.Accounts.User.profile_changeset(user, %{}), as: :profile),
        password_form:
          to_form(Dran.Accounts.User.update_password_changeset(user, %{}), as: :password),
        locale_form: locale_form(socket.assigns.locale),
        google_linked: Dran.Accounts.google_linked?(user)
      )

    {:ok, apply_tab(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, apply_tab(socket, socket.assigns.live_action, %{})}
  end

  defp apply_tab(socket, :account, _params) do
    socket
    |> assign(active_tab: :account, active_nav: "settings", page_title: gettext("Account"))
  end

  defp apply_tab(socket, _action, _params) do
    socket
    |> assign(active_tab: :account, active_nav: "settings", page_title: gettext("Account"))
  end

  # Resolves the %User{} (or nil) behind the LiveView session. The session
  # stores the email; `nil` falls back to the no-user case (empty key lists).
  defp session_user(session) do
    case Auth.from_session(session) do
      %{current_user: email} when is_binary(email) ->
        Dran.Accounts.get_user_by_email(email)

      _ ->
        nil
    end
  end

  @impl true
  def handle_event("save_profile", %{"profile" => profile_params}, socket) do
    case Dran.Accounts.update_profile(socket.assigns.current_user_struct, profile_params) do
      {:ok, updated_user} ->
        socket =
          socket
          |> put_flash(:info, gettext("Profile updated"))
          |> assign(
            current_user_struct: updated_user,
            profile_form:
              to_form(Dran.Accounts.User.profile_changeset(updated_user, %{}), as: :profile)
          )

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, profile_form: to_form(changeset, as: :profile))}
    end
  end

  @impl true
  def handle_event("save_password", %{"password" => password_params}, socket) do
    case Dran.Accounts.update_password(socket.assigns.current_user_struct, password_params) do
      {:ok, _updated_user} ->
        socket =
          socket
          |> put_flash(:info, gettext("Password changed"))
          |> assign(
            password_form:
              to_form(
                Dran.Accounts.User.update_password_changeset(
                  socket.assigns.current_user_struct,
                  %{}
                ),
                as: :password
              )
          )

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, password_form: to_form(changeset, as: :password))}
    end
  end

  @impl true
  def handle_event("regenerate_api_token", _params, socket) do
    case Dran.Accounts.regenerate_api_token(socket.assigns.current_user_struct) do
      {:ok, updated_user} ->
        socket =
          socket
          |> assign(current_user_struct: updated_user)
          |> put_flash(:info, gettext("API key regenerated — copy the new token now"))

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not regenerate the API key"))}
    end
  end

  @impl true
  def handle_event("unlink_google", _params, socket) do
    case Dran.Accounts.unlink_google(socket.assigns.current_user_struct) do
      {:ok, updated_user} ->
        socket =
          socket
          |> put_flash(:info, gettext("Google account unlinked"))
          |> assign(current_user_struct: updated_user, google_linked: false)

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not unlink Google account"))}
    end
  end

  # ── Language ──────────────────────────────────────────────────────────────
  #
  # The preference is durable (users.locale). Changing it changes the language
  # of *every* string on the page — including the ones inside the layout and
  # the components, which LiveView's in-place diffing does not always carry —
  # so the honest move is to remount: `push_navigate` to this same tab makes
  # the LiveView mount again, read `users.locale` and render the whole page in
  # the new language. The flash is translated after the switch, so it lands in
  # the language the user just picked.
  @impl true
  def handle_event("save_locale", %{"locale" => %{"locale" => locale}}, socket) do
    case Dran.Accounts.update_locale(socket.assigns.current_user_struct, locale) do
      {:ok, updated_user} ->
        Gettext.put_locale(DranWeb.Gettext, updated_user.locale)

        {:noreply,
         socket
         |> assign(
           current_user_struct: updated_user,
           locale: updated_user.locale,
           locale_form: locale_form(updated_user.locale)
         )
         |> put_flash(:info, gettext("Language updated"))
         |> push_navigate(to: ~p"/settings/account")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save the preference"))}
    end
  end

  # One-field form driving the language select. Values are the locale codes the
  # app ships catalogs for; the labels stay in their own language on purpose.
  defp locale_form(locale) do
    to_form(%{"locale" => locale || DranWeb.Gettext.app_default_locale()}, as: :locale)
  end

  defp locale_options do
    Enum.map(DranWeb.Gettext.supported_locales(), fn
      "en" -> {"English", "en"}
      "es" -> {"Español", "es"}
      other -> {other, other}
    end)
  end

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
      nav={:instance}
    >
      <div class="w-full">
        <div class="w-full space-y-8">
          <div>
            <h1 class="text-title">
              {gettext("Account")}
            </h1>
            <p class="text-caption mt-1">
              {gettext("Your profile, password and connected accounts.")}
            </p>
          </div>

          <div class="space-y-6">
            <.section
              title={gettext("Profile")}
              caption={gettext("Change your display name.")}
              icon="hero-user"
            >
              <.form
                for={@profile_form}
                id="profile-form"
                phx-submit="save_profile"
                class="space-y-4"
              >
                <.input
                  field={@profile_form[:name]}
                  label={gettext("Name")}
                  placeholder={gettext("Your name")}
                />
                <button
                  type="submit"
                  class="btn btn-primary btn-sm"
                  phx-disable-with={gettext("Saving…")}
                >
                  {gettext("Save")}
                </button>
              </.form>
            </.section>

            <.section
              title={gettext("Password")}
              caption={gettext("Change your password.")}
              icon="hero-lock-closed"
            >
              <.form
                for={@password_form}
                id="password-form"
                phx-submit="save_password"
                class="space-y-4"
              >
                <.input
                  :if={@current_user_struct.password_hash}
                  field={@password_form[:current_password]}
                  type="password"
                  label={gettext("Current password")}
                  placeholder="••••••••"
                />
                <.input
                  field={@password_form[:password]}
                  type="password"
                  label={gettext("New password")}
                  placeholder="••••••••"
                />
                <button
                  type="submit"
                  class="btn btn-primary btn-sm"
                  phx-disable-with={gettext("Saving…")}
                >
                  {gettext("Change password")}
                </button>
              </.form>
            </.section>

            <%!-- The account's ONE key. It is minted when the account is
                   created (`Accounts.insert_user/2`), so this section SHOWS it
                   instead of offering to create another one: copy, or
                   regenerate in place. --%>
            <.section
              title={gettext("API key")}
              caption={gettext("The key your agents use to call the Dran REST API.")}
              icon="hero-key"
            >
              <div class="flex items-center gap-2">
                <code
                  id="account-api-token"
                  data-token={@current_user_struct.api_token}
                  class="flex-1 text-sm font-mono bg-base-100 rounded-md px-3 py-2 border border-base-300 select-all break-all"
                >
                  {@current_user_struct.api_token}
                </code>
                <button
                  type="button"
                  id="copy-account-api-key-btn"
                  data-copy-target="account-api-token"
                  phx-hook=".CopyAccountApiToken"
                  class="btn btn-outline btn-sm gap-1 transition-all active:scale-95"
                  title={gettext("Copy")}
                >
                  <span data-copy-icon class="flex items-center gap-1">
                    <.icon name="hero-clipboard-document" class="size-4" />
                    {gettext("Copy")}
                  </span>
                  <span data-check-icon class="hidden items-center gap-1">
                    <.icon name="hero-clipboard-document-check" class="size-4" />
                    {gettext("Copied!")}
                  </span>
                </button>
              </div>

              <p class="text-xs text-base-content/60 mt-3">
                {gettext(
                  "It reads and writes as you do. Regenerating it invalidates the current one immediately."
                )}
              </p>

              <button
                type="button"
                id="regenerate-api-key-btn"
                phx-click="regenerate_api_token"
                data-confirm={
                  gettext(
                    "Regenerate your API key? Every client using the current one stops working immediately."
                  )
                }
                class="btn btn-ghost btn-sm gap-1.5 text-error mt-2"
                phx-disable-with={gettext("Regenerating…")}
              >
                <.icon name="hero-arrow-path" class="size-4" />
                {gettext("Regenerate")}
              </button>
            </.section>

            <.section
              title={gettext("Language")}
              caption={gettext("Interface language for your account.")}
              icon="hero-language"
            >
              <.form
                for={@locale_form}
                id="locale-form"
                phx-change="save_locale"
                class="space-y-3"
              >
                <.input
                  field={@locale_form[:locale]}
                  type="select"
                  label={gettext("Language")}
                  options={locale_options()}
                  class="w-full sm:max-w-xs"
                />
                <p class="text-xs text-base-content/60">
                  {gettext(
                    "English is the default. Your choice is saved to your account and applies to the whole instance."
                  )}
                </p>
              </.form>
            </.section>

            <.section
              title={gettext("Google Account")}
              caption={gettext("Link or unlink your Google account.")}
              icon="hero-globe-alt"
            >
              <div class="flex items-center gap-3">
                <.icon
                  name={if @google_linked, do: "hero-check-badge", else: "hero-link-slash"}
                  class="size-5"
                />
                <span class="text-sm text-base-content/70">
                  {if @google_linked,
                    do: gettext("Google account linked"),
                    else: gettext("No Google account linked")}
                </span>
              </div>

              <div class="mt-4">
                <%= if @google_linked do %>
                  <button
                    type="button"
                    phx-click="unlink_google"
                    data-confirm={gettext("Are you sure you want to unlink your Google account?")}
                    class="btn btn-ghost btn-sm gap-1.5 text-error"
                    phx-disable-with={gettext("Unlinking…")}
                  >
                    <.icon name="hero-link-slash" class="size-4" />
                    {gettext("Unlink")}
                  </button>
                <% else %>
                  <a href={~p"/auth/google"} class="btn btn-outline btn-sm gap-1.5">
                    <.icon name="hero-globe-alt" class="size-4" />
                    {gettext("Link Google account")}
                  </a>
                <% end %>
              </div>
            </.section>

            <%!-- Self-contained copy: reads the token from the code block's
                   `data-token` (the id in `data-copy-target`), with a
                   clipboard fallback. --%>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyAccountApiToken">
              export default {
                mounted() {
                  this.el.addEventListener("click", () => {
                    const target = document.getElementById(this.el.dataset.copyTarget);
                    if (!target) return;
                    const text = target.dataset.token;
                    if (!text) return;
                    const copied = () => {
                      const icon = this.el.querySelector("[data-copy-icon]");
                      const check = this.el.querySelector("[data-check-icon]");
                      if (icon && check) {
                        icon.classList.add("hidden");
                        check.classList.remove("hidden");
                        check.classList.add("flex");
                        setTimeout(() => {
                          icon.classList.remove("hidden");
                          check.classList.add("hidden");
                          check.classList.remove("flex");
                        }, 1500);
                      }
                    };
                    if (navigator.clipboard && navigator.clipboard.writeText) {
                      navigator.clipboard.writeText(text).then(copied);
                    } else {
                      const ta = document.createElement("textarea");
                      ta.value = text;
                      ta.setAttribute("readonly", "");
                      ta.style.position = "absolute";
                      ta.style.left = "-9999px";
                      document.body.appendChild(ta);
                      ta.select();
                      try { document.execCommand("copy"); } catch (_e) { /* noop */ }
                      document.body.removeChild(ta);
                      copied();
                    }
                  });
                }
              }
            </script>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
