Postgrex.Types.define(
  Dran.PostgresTypes,
  Ecto.Adapters.Postgres.extensions() ++ [Pgvector.Extensions.Vector],
  []
)
