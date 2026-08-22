defmodule DranWeb.Admin do
  @moduledoc """
  Shared components for the `/admin` section — a standardized modal and a
  standardized section wrapper. Every admin page (Users, Workspaces, Models,
  System, Jobs) should use these so tables, modals and headers look and behave
  identically.
  """

  use DranWeb, :html

  @doc """
  Standardized modal dialog.

  - `show` gates visibility.
  - `on_close` is the LiveView event fired by the X button and `phx-click-away`.
  - The form (including its Cancel / submit footer) goes inside the default slot.

  ## Example

      <.admin_modal
        id="user-modal"
        :if={@show_user_modal}
        title={gettext("Add User")}
        on_close="close_user_modal"
      >
        <.form for={@user_form} phx-submit="save_user" class="space-y-4">
          ...
        </.form>
      </.admin_modal>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :show, :boolean, default: false
  attr :on_close, :string, required: true
  attr :max_w, :string, default: "max-w-lg"
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div :if={@show} class="fixed inset-0 z-50 flex items-center justify-center bg-black/50">
      <div
        id={@id}
        class={["card bg-base-100 border border-base-300 shadow-xl w-full", @max_w]}
        phx-click-away={@on_close}
      >
        <div class="card-body">
          <div class="flex items-center justify-between mb-2">
            <h3 class="text-lg font-semibold">{@title}</h3>
            <button type="button" phx-click={@on_close} class="btn btn-ghost btn-xs btn-circle">
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Standardized admin section: `surface-2` card with a header carrying an
  icon badge, a title and an optional caption.

  ## Example

      <.admin_section title={gettext("Existing Users")} icon="hero-user-group">
        <div class="overflow-x-auto">
          <table class="table table-sm">...</table>
        </div>
      </.admin_section>
  """
  attr :title, :string, required: true
  attr :caption, :string, default: nil
  attr :icon, :string, required: true
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <section class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-primary/10">
          <.icon name={@icon} class="size-4 text-primary" />
        </div>
        <div class="min-w-0 flex-1">
          <h2 class="text-heading">{@title}</h2>
          <p :if={@caption} class="text-caption mt-0.5">{@caption}</p>
        </div>
      </header>
      <div class="p-5">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end
end
