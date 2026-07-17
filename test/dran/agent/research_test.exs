defmodule Dran.Agent.ResearchTest do
  # Unit tests for Dran.Agent.Research.execute_tool/3.
  # Uses DataCase because the page-limit check reads runtime defaults from
  # Dran.Settings (DB-backed with fallback to module defaults).
  use Dran.DataCase, async: true

  alias Dran.Agent.Research
  alias Dran.Agent.Research.State
  alias Dran.Agent.Session

  defp build_session(attrs \\ []) do
    struct(
      %Session{
        id: Ecto.UUID.generate(),
        context_id: Ecto.UUID.generate(),
        agent_type: "research",
        input: "test topic",
        status: "running"
      },
      attrs
    )
  end

  defp build_state(attrs) do
    struct(
      %State{
        session: build_session(),
        pages_created: 0,
        opts: []
      },
      attrs
    )
  end

  describe "create_page page-limit" do
    test "returns error when default page limit (10) is reached" do
      state = build_state(pages_created: 10)

      {{:error, msg}, new_state} =
        Research.execute_tool("create_page", %{"title" => "x", "body" => "y"}, state)

      assert msg =~ "maximum" or msg =~ "page limit"
      # state is returned unchanged when blocked
      assert new_state.pages_created == 10
    end

    test "respects custom :max_pages option from state.opts" do
      state = build_state(pages_created: 3, opts: [max_pages: 3])

      {{:error, msg}, _} =
        Research.execute_tool("create_page", %{"title" => "x", "body" => "y"}, state)

      assert msg =~ "maximum of 3"
    end

    test "respects custom :max_pages when given as a map" do
      state = build_state(pages_created: 2, opts: %{max_pages: 2})

      {{:error, msg}, _} =
        Research.execute_tool("create_page", %{"title" => "x", "body" => "y"}, state)

      assert msg =~ "maximum of 2"
    end

    test "does not block when under the limit" do
      # pages_created strictly below the limit should NOT trip the guard:
      # execution proceeds into Brain.create_page and the page is created.
      {:ok, ctx} = Dran.Brain.create_context(%{name: "Limit Test", slug: "limit-test"})

      session = build_session(context_id: ctx.id)
      state = build_state(pages_created: 9, opts: [max_pages: 10], session: session)

      {{:ok, page}, new_state} =
        Research.execute_tool("create_page", %{"title" => "x", "body" => "y"}, state)

      assert page.title == "x"
      assert new_state.pages_created == 10
    end
  end
end
