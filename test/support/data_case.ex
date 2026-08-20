defmodule Dran.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Dran.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Dran.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Dran.DataCase
    end
  end

  setup tags do
    Dran.DataCase.setup_sandbox(tags)

    # Many tests assume the default "personal" workspace exists (created by
    # seeds in dev, absent in test). Create it by default unless a test opts
    # out with `@tag :no_default_workspace`.
    unless tags[:no_default_workspace] do
      Dran.DataCase.ensure_workspace!()
    end

    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Dran.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Ensures the default "personal" workspace exists, creating it if needed.

  Many tests assume the default workspace is present (it's normally created
  by seeds in dev, but not in the test DB). Returns the workspace struct.
  """
  def ensure_workspace!(slug \\ "personal", name \\ "Personal") do
    Dran.Brain.get_workspace_by_slug(slug) ||
      case Dran.Brain.create_workspace(%{name: name, slug: slug}) do
        {:ok, ws} ->
          ws

        {:error, changeset} ->
          raise "Could not create workspace #{slug}: #{inspect(changeset.errors)}"
      end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
