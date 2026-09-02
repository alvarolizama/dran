defmodule DranWeb.ResourceComponentsModalTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DranWeb.ResourceComponents

  # HEEx wrapper so slots are passed with real template syntax — the
  # component under test is rendered exactly as LiveViews consume it.
  # render_component/3 requires a fun component: use Phoenix.Component.
  use Phoenix.Component

  defp render_modal(opts) do
    assigns =
      Map.new(opts)
      |> Map.put_new(:pill, nil)
      |> Map.put_new(:form_id, nil)
      |> Map.put_new(:submit_label, nil)
      |> Map.put_new(:with_sidebar, false)
      |> Map.put_new(:with_left, false)

    render_component(
      fn assigns ->
        ~H"""
        <ResourceComponents.resource_modal
          id={@id}
          title={@title}
          pill={@pill}
          on_close="close_modal"
          form_id={@form_id}
          submit_label={@submit_label}
        >
          <:sidebar :if={@with_sidebar}>
            <select name="task[status]"><option value="todo">todo</option></select>
          </:sidebar>
          <:left :if={@with_left}>
            <button type="button">Archivar</button>
          </:left>
          <p id="modal-main-content">main</p>
        </ResourceComponents.resource_modal>
        """
      end,
      assigns
    )
  end

  test "renders header pill and title" do
    html = render_modal(id: "test-modal", title: "Editar — Diseñar onboarding", pill: "TASK")

    assert html =~ "Editar — Diseñar onboarding"
    assert html =~ "TASK"
    assert html =~ "main"
  end

  test "renders the dialog with close affordance" do
    html = render_modal(id: "test-modal", title: "T")

    assert html =~ ~s(role="dialog")
    assert html =~ ~s(aria-modal="true")
    assert html =~ "hero-x-mark"
  end

  test "close affordances fire on_close: ✕ button, ESC keydown on window, click-away on overlay" do
    html = render_modal(id: "test-modal", title: "T")

    assert html =~ ~s(phx-click="close_modal")
    assert html =~ ~s(phx-window-keydown="close_modal")
    assert html =~ ~s(phx-key="Escape")
    assert html =~ ~s(phx-click-away="close_modal")
  end

  test "sidebar slot renders in an aside" do
    html = render_modal(id: "test-modal", title: "T", with_sidebar: true)

    assert html =~ "<aside"
    assert html =~ "task[status]"
  end

  test "no sidebar slot renders no aside" do
    html = render_modal(id: "test-modal", title: "T")

    refute html =~ "<aside"
  end

  test "footer save button targets the form via form= attribute" do
    html =
      render_modal(
        id: "test-modal",
        title: "T",
        form_id: "task-modal-form",
        submit_label: "Guardar"
      )

    assert html =~ ~s(type="submit")
    assert html =~ ~s(form="task-modal-form")
    assert html =~ "Guardar"
  end

  test "no form_id renders no save button" do
    html = render_modal(id: "test-modal", title: "T")

    refute html =~ ~s(type="submit")
  end

  test "footer renders left slot (destructive actions)" do
    html = render_modal(id: "test-modal", title: "T", with_left: true)

    assert html =~ "Archivar"
  end
end
