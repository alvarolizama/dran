defmodule Dran.Agent.ResearchTest do
  # Pure unit tests for Dran.Agent.Research.execute_tool/3.
  # No DB access required: we only exercise the limit-check logic, which
  # short-circuits before Brain.create_page is ever called.
  use ExUnit.Case, async: true

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
      # pages_created strictly below the limit should NOT trip the guard.
      # We pick pages_created = max - 1 with max_pages: 10, so the guard
      # must NOT fire and execution must proceed into Brain.create_page.
      #
      # Brain.create_page requires a DB sandbox we don't set up here, so it
      # raises a DBConnection.OwnershipError. That exception is the proof
      # we reached the create path (the limit guard returns {:error, _},
      # never raises). We assert on that: the guard did NOT short-circuit.
      state = build_state(pages_created: 9, opts: [max_pages: 10])

      assert_raise DBConnection.OwnershipError, fn ->
        Research.execute_tool("create_page", %{"title" => "x", "body" => "y"}, state)
      end
    end
  end
end
