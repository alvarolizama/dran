defmodule DranWeb.WorkflowsStepEditorRegressionTest do
  @moduledoc """
  Regression tests for two P0 bugs that were invisible to LiveViewTest because
  they involve client-side state (JavaScript hooks + morphdom).

  The existing suite only exercises the server pipeline (`contract_json` via
  form submit), which is why both bugs survived review and production deploy.
  """
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.{DataCase, Workflows}

  # ──────────────────────────────────────────────────────────────────────
  # P0-1: [data-visual-body] wrapper exists and encloses all panels
  #
  # Root cause: step_modal_tabs.js:28 does `this.el.querySelector("[data-visual-body]")`
  # but no template element carried that attribute. With visualBody = null the guard
  # `if (this.jsonEl && this.visualBody)` in mounted() fails → _wireVisual /
  # _wireToggle / _buildFromJson / _wireCtxSearch never run. The entire visual
  # contract editor is dead — tabs switch but panels stay empty.
  #
  # Fix: wrap the five panels inside <div data-visual-body>. Also moved `hidden`
  # from the JSON-wrapper div onto the textarea itself, because jsonEl IS the
  # textarea and `_wireToggle` toggles `jsonEl.hidden`.
  # ──────────────────────────────────────────────────────────────────────

  test "step-editor renders data-visual-body wrapping all panels", %{conn: conn} do
    ws = DataCase.ensure_workspace!()

    {:ok, workflow} =
      Workflows.create_workflow(%{
        "workspace_id" => ws.id,
        "title" => "Reg WF",
        "slug" => "reg-wf",
        "kind" => "one_shot",
        "status" => "draft"
      })

    {:ok, step} =
      Workflows.create_step(workflow, %{
        "title" => "Reg Step",
        "slug" => "reg-step",
        "intent" => "algo"
      })

    conn = session(conn, ws, true)

    {:ok, view, html} = live(conn, ~p"/#{ws.slug}/workflows/#{workflow.slug}?step=#{step.id}")

    assert has_element?(view, "[data-visual-body]"),
           "[data-visual-body] must exist; without it the JS hook returns early and the visual editor is dead"

    # Each panel must be a descendant of the visual body (not floating outside).
    for panel <- ["intent", "claims", "gates", "grafo", "contexto"] do
      assert has_element?(view, "[data-visual-body] [data-panel=\"#{panel}\"]"),
             "panel #{panel} must be inside [data-visual-body]"
    end

    # The textarea with data-contract-json must also be present (outside the visual body).
    assert has_element?(view, "[data-testid='step-contract']")

    # The textarea itself must carry `hidden` so the toggle can reveal it.
    assert html =~ "data-contract-json"
    # hidden may appear on a separate line from data-contract-json in the rendered HTML.
    assert html =~ ~r/data-contract-json[\s\S]*?hidden/
  end

  # ──────────────────────────────────────────────────────────────────────
  # Controles del mini-canvas del Grafo: el botón de agregar nodo
  # ([data-gc-add]) y el de reordenar por niveles ([data-gc-tidy]) deben
  # renderizarse dentro del contenedor del canvas. Son overlay client-side
  # (el hook GraphCanvas los captura por delegación), pero el HTML es
  # server-rendered: si alguien los borra del template el feature muere en
  # silencio, igual que pasó con [data-visual-body].
  # ──────────────────────────────────────────────────────────────────────
  test "grafo canvas renders its overlay controls (add + tidy)", %{conn: conn} do
    ws = DataCase.ensure_workspace!()

    {:ok, workflow} =
      Workflows.create_workflow(%{
        "workspace_id" => ws.id,
        "title" => "Canvas WF",
        "slug" => "canvas-wf",
        "kind" => "one_shot",
        "status" => "draft"
      })

    {:ok, step} =
      Workflows.create_step(workflow, %{
        "title" => "Canvas Step",
        "slug" => "canvas-step",
        "intent" => "algo"
      })

    conn = session(conn, ws, true)

    {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/#{workflow.slug}?step=#{step.id}")

    assert has_element?(view, "[data-panel='grafo'] [data-graph-canvas]"),
           "el contenedor del mini-canvas debe existir"

    assert has_element?(view, "[data-graph-canvas] [data-gc-add]"),
           "el botón de agregar nodo debe vivir dentro del canvas"

    assert has_element?(view, "[data-graph-canvas] [data-gc-tidy]"),
           "el botón de reordenar por niveles debe vivir dentro del canvas"
  end

  # ──────────────────────────────────────────────────────────────────────
  # P0-2: move_step discards its result — consecutive drags lose the first
  #
  # Root cause: handle_event("move_step", ...) ends with a bare
  # `{:noreply, socket}` AFTER the with block. The with's {:noreply, assign(...)}
  # is computed but DISCARDED, so socket.assigns.positions never updates.
  # persist_positions writes the full map from stale positions, overwriting
  # the previous drag.
  #
  # Fix: return the with's result directly (merge else branch into one clause).
  # ──────────────────────────────────────────────────────────────────────

  test "consecutive move_steps preserve both positions", %{conn: conn} do
    ws = DataCase.ensure_workspace!()

    {:ok, workflow} =
      Workflows.create_workflow(%{
        "workspace_id" => ws.id,
        "title" => "Drag WF",
        "slug" => "drag-wf",
        "kind" => "one_shot",
        "status" => "draft"
      })

    {:ok, _a} = Workflows.create_step(workflow, %{"title" => "Card A", "slug" => "card-a"})
    {:ok, _b} = Workflows.create_step(workflow, %{"title" => "Card B", "slug" => "card-b"})

    conn = session(conn, ws, true)

    {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/#{workflow.slug}")

    steps = Workflows.list_steps(workflow)
    a = Enum.find(steps, &(&1.slug == "card-a"))
    b = Enum.find(steps, &(&1.slug == "card-b"))

    # Drag 1: Card A → (100, 100)
    view
    |> element("#wfe-canvas")
    |> render_hook("move_step", %{"step-id" => a.id, "x" => "100", "y" => "100"})

    after_first = Map.new(Workflows.list_steps(workflow), &{&1.slug, {&1.pos_x, &1.pos_y}})

    assert after_first["card-a"] == {100, 100},
           "first drag should persist position (100,100)"

    # Drag 2: Card B → (300, 300) WITHOUT an intermediate reload.
    # Bug before fix: socket.assigns.positions was stale (never updated by
    # drag 1), so persist_positions wrote the original levels layout for card A,
    # effectively reverting drag 1.
    view
    |> element("#wfe-canvas")
    |> render_hook("move_step", %{"step-id" => b.id, "x" => "300", "y" => "300"})

    after_second = Map.new(Workflows.list_steps(workflow), &{&1.slug, {&1.pos_x, &1.pos_y}})

    assert after_second["card-a"] == {100, 100},
           "card A's position must survive the second drag (was reverted to level layout before fix)"

    assert after_second["card-b"] == {300, 300},
           "card B's new position must be correct"
  end

  # ──────────────────────────────────────────────────────────────────────
  # Helper
  # ──────────────────────────────────────────────────────────────────────

  defp session(conn, workspace, is_owner \\ true) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, "test_user")
    |> Plug.Conn.put_session(:workspace_slug, workspace.slug)
    |> Plug.Conn.put_session(:is_owner, is_owner)
  end
end
