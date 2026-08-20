defmodule DranWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use DranWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint DranWeb.Endpoint

      use DranWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import DranWeb.ConnCase
    end
  end

  setup tags do
    Dran.DataCase.setup_sandbox(tags)

    # Many LiveView tests assume the default "personal" workspace exists AND
    # that the "test_user" session user has owner access (the old behavior
    # treated pre-multi-user sessions as full admin). Create both by default
    # unless a test opts out with `@tag :no_default_workspace`.
    unless tags[:no_default_workspace] do
      Dran.DataCase.ensure_workspace!()

      # Ensure "test_user" exists as the instance owner so that
      # require_instance_owner / require_workspace_role pass. Tests that
      # exercise access DENIAL create their own non-owner users.
      case Dran.Accounts.get_user_by_email("test_user") do
        nil ->
          # Email format validation requires "@", but the session user is
          # "test_user" — create directly via Repo to bypass validation.
          %Dran.Accounts.User{}
          |> Ecto.Changeset.change(%{
            email: "test_user",
            name: "Test User",
            is_owner: true,
            api_token: Dran.Accounts.User.generate_api_token()
          })
          |> Dran.Repo.insert!()

        user ->
          unless user.is_owner do
            user
            |> Ecto.Changeset.change(is_owner: true)
            |> Dran.Repo.update!()
          end
      end

      # Give test_user owner membership in the default workspace so
      # list_user_workspaces/1 returns it and the home/panel render it.
      ws = Dran.DataCase.ensure_workspace!()
      user = Dran.Accounts.get_user_by_email("test_user")

      unless Dran.Accounts.user_in_workspace?(user, ws) do
        Dran.Accounts.add_user_to_workspace(user, ws)
      end
    end

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
