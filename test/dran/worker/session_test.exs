defmodule Dran.Worker.SessionTest do
  # Pure changeset tests — no Repo access, so ExUnit.Case suffices. (Using
  # DataCase here checked out a sandbox connection concurrently with sync
  # tests running in shared mode, which corrupts their ownership.)
  use ExUnit.Case, async: true

  alias Dran.Worker.Session

  test "rejects invalid status" do
    changeset =
      Session.changeset(%Session{}, %{
        worker_type: "ask",
        input: "x",
        workspace_id: Ecto.UUID.generate(),
        status: "bogus"
      })

    refute changeset.valid?
  end

  test "accepts a valid status" do
    for status <- ~w(pending running done failed cancelled) do
      changeset =
        Session.changeset(%Session{}, %{
          worker_type: "ask",
          input: "x",
          workspace_id: Ecto.UUID.generate(),
          status: status
        })

      assert changeset.valid?, "expected #{status} to be valid"
    end
  end
end
