#!/bin/sh
# Dran container entrypoint.
#
# Runs Dran.Release.setup/0 (create DB if missing → migrate → seed default
# context) before starting the Phoenix release. On a fresh database it
# creates the schema and the default context. On subsequent deploys it
# short-circuits (DB already exists) and only runs pending migrations.
# Demo content (goals, todos, notes) is NOT seeded in prod — use
# `bin/dran eval Dran.Release.seed` manually for that.
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
