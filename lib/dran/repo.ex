defmodule Dran.Repo do
  use Ecto.Repo,
    otp_app: :dran,
    adapter: Ecto.Adapters.Postgres
end
