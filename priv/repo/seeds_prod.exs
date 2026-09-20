# Production seed for Dran — evaluated by Dran.Release.seed/0 on EVERY deploy
# (container entrypoint → Dran.Release.setup/0). It is NOT the demo dataset
# (priv/repo/seeds.exs): that one creates content with accounts whose passwords
# are public in this repository, and it is reachable only through
# Dran.Release.seed_demo/0, which refuses to run inside a release.
#
# Rules:
#   * IDEMPOTENT — setup/0 runs on every deploy, so this file must be a
#     get_by-then-insert (or an on_conflict), never a blind insert.
#   * OPT-IN for credentials: the owner is created only when
#     DRAN_ADMIN_PASSWORD is set (8+ chars). Without it the boot creates nobody
#     and the first account comes in through /setup. Never a fallback password
#     living in this repository.
#   * The account is created as instance owner, so whoever logs in lands on the
#     instance's content right away.
#
# The rest of the production state is not seeded here: the instance row is
# created by Dran.Release.seed_context/0 (idempotent: an existing row is left
# alone, so a rename done in the UI survives every deploy).

alias Dran.Accounts

case System.get_env("DRAN_ADMIN_PASSWORD") do
  password when is_binary(password) and password != "" ->
    email = System.get_env("DRAN_ADMIN_EMAIL", "admin@dran.local")
    name = System.get_env("DRAN_ADMIN_NAME", "Admin")

    case Accounts.get_user_by_email(email) do
      nil ->
        attrs = %{"name" => name, "email" => email, "password" => password}

        case Accounts.create_user_with_password(attrs) do
          {:ok, user} ->
            {:ok, owner} = Accounts.update_user(user, %{is_owner: true})

            IO.puts("[seed] instance owner #{owner.email} created")

            owner

          {:error, changeset} ->
            # Two replicas racing the same boot: the loser hits the email's
            # unique constraint. That is not an error — the account exists.
            if Keyword.has_key?(changeset.errors, :email) do
              IO.puts("[seed] #{email} was created by another instance, skipping")
              :ok
            else
              raise "[seed] could not create the owner #{email}: " <>
                      inspect(changeset.errors)
            end
        end

      existing ->
        IO.puts("[seed] account #{existing.email} already exists, skipping")
        existing
    end

  _ ->
    IO.puts(
      "[seed] DRAN_ADMIN_PASSWORD not set — no account is created here; " <>
        "the first one comes from the /setup screen"
    )

    :ok
end
