defmodule DranWeb.LoginLive do
  @moduledoc """
  Login page for single-user authentication.
  """

  use DranWeb, :live_view

  import Phoenix.Controller, only: [get_csrf_token: 0]

  alias Dran.Auth

  @impl true
  def mount(_params, session, socket) do
    context_slug = session["context_slug"] || Auth.default_context_slug()

    {:ok,
     assign(socket,
       context_slug: context_slug,
       error: nil,
       page_title: "Login"
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-base-200">
      <div class="card w-full max-w-sm bg-base-100 shadow-xl border border-base-300">
        <div class="card-body">
          <h1 class="text-2xl font-bold text-center mb-1">Dran</h1>
          <p class="text-sm text-base-content/60 text-center mb-6">
            Sign in to your second brain
          </p>

          <form action={~p"/session"} method="post" class="space-y-3">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />

            <div>
              <label class="text-sm font-medium text-base-content/70 block mb-1">Username</label>
              <input
                type="text"
                name="login[username]"
                placeholder="admin"
                autocomplete="username"
                required
                class="w-full px-3 py-2 rounded-lg border border-base-300 bg-base-100 focus:outline-none focus:ring-1 focus:ring-primary"
              />
            </div>

            <div>
              <label class="text-sm font-medium text-base-content/70 block mb-1">Password</label>
              <input
                type="password"
                name="login[password]"
                placeholder="••••••"
                autocomplete="current-password"
                required
                class="w-full px-3 py-2 rounded-lg border border-base-300 bg-base-100 focus:outline-none focus:ring-1 focus:ring-primary"
              />
            </div>

            <p :if={@error} class="text-sm text-red-600">{@error}</p>

            <button type="submit" class="btn btn-primary w-full mt-2">
              Sign in
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
