defmodule Dran.Agent.SessionTest do
  use Dran.DataCase, async: true

  alias Dran.Agent.Session

  test "rejects invalid status" do
    changeset =
      Session.changeset(%Session{}, %{
        agent_type: "research",
        input: "x",
        context_id: Ecto.UUID.generate(),
        status: "bogus"
      })

    refute changeset.valid?
  end

  test "accepts a valid status" do
    for status <- ~w(pending running done failed cancelled) do
      changeset =
        Session.changeset(%Session{}, %{
          agent_type: "research",
          input: "x",
          context_id: Ecto.UUID.generate(),
          status: status
        })

      assert changeset.valid?, "expected #{status} to be valid"
    end
  end
end
