#!/bin/sh
# Dran container entrypoint.
#
# Runs Dran.Release.setup/0 (create DB if missing → migrate → seed, all
# idempotent) before starting the Phoenix release. On a fresh database it
# creates the schema and seeds the default context. On subsequent deploys it
# short-circuits (DB already exists) and only runs pending migrations + the
# idempotent seed. A failed setup aborts boot (Coolify rolls back) instead
# of serving against an un-migrated schema.
#
# Set SKIP_MIGRATIONS=1 to bypass (one-off task containers).
set -e

if [ "$SKIP_MIGRATIONS" = "1" ]; then
  echo "[entrypoint] SKIP_MIGRATIONS=1, skipping setup."
else
  echo "[entrypoint] running setup (create DB → migrate → seed)..."
  bin/dran eval "Dran.Release.setup"
fi

echo "[entrypoint] starting dran release..."
exec bin/dran start
