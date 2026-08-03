defmodule DranWeb.SetupLive do
  @moduledoc """
  First-run setup: creates the initial admin user.

  Only available while the users table is empty. Once any user exists,
  this page redirects to /login so nobody can self-promote later.
  """

  use DranWeb, :live_view

  import Phoenix.Controller, only: [get_csrf_token: 0]

  alias Dran.Accounts

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.any_users?() do
      {:ok, redirect(socket, to: ~p"/login")}
    else
      {:ok,
       assign(socket,
         error: nil,
         page_title: "Setup"
       )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-base-200">
      <div class="card w-full max-w-sm bg-base-100 shadow-xl border border-base-300">
        <div class="card-body">
          <h1 class="text-2xl font-bold text-center mb-1">Dran</h1>
          <p class="text-sm text-base-content/60 text-center mb-6">
            Create your admin account to get started
          </p>

          <form action={~p"/setup"} method="post" class="space-y-3">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />

            <div>
              <label class="text-sm font-medium text-base-content/70 block mb-1">Email</label>
              <input
                type="email"
                name="setup[email]"
                placeholder="you@example.com"
                autocomplete="email"
                required
                class="w-full px-3 py-2 rounded-lg border border-base-300 bg-base-100 focus:outline-none focus:ring-1 focus:ring-primary"
              />
            </div>

            <div>
              <label class="text-sm font-medium text-base-content/70 block mb-1">Password</label>
              <input
                type="password"
                name="setup[password]"
                placeholder="8+ characters"
                autocomplete="new-password"
                minlength="8"
                required
                class="w-full px-3 py-2 rounded-lg border border-base-300 bg-base-100 focus:outline-none focus:ring-1 focus:ring-primary"
              />
            </div>

            <div>
              <label class="text-sm font-medium text-base-content/70 block mb-1">
                Confirm password
              </label>
              <input
                type="password"
                name="setup[password_confirmation]"
                placeholder="••••••••"
                autocomplete="new-password"
                minlength="8"
                required
                class="w-full px-3 py-2 rounded-lg border border-base-300 bg-base-100 focus:outline-none focus:ring-1 focus:ring-primary"
              />
            </div>

            <p :if={@error} class="text-sm text-red-600">{@error}</p>

            <button type="submit" class="btn btn-primary w-full mt-2">
              Create admin account
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
