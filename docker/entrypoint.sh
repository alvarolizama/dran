#!/bin/sh
# Dran container entrypoint.
#
# Runs Dran.Release.setup/0 (create DB if missing → migrate → seed default
# context → backfill personal workspaces) before starting the Phoenix release.
# On a fresh database it creates the schema and the default context. On
# subsequent deploys it short-circuits (DB already exists) and only runs
# pending migrations. Demo content (goals, todos, notes) is NOT seeded in prod
# — use `bin/dran eval Dran.Release.seed` manually for that.
#
# Env vars:
#   SKIP_MIGRATIONS=1   bypass setup entirely (one-off task containers).
#   DRAN_RESET=wipe     DESTRUCTIVE: drop the whole database schema (every
#                       workspace with its content, every user, key and
#                       setting) and rebuild it empty, so the instance is back
#                       at /setup and you can onboard from scratch.
#                       The value must be exactly "wipe" — anything else is
#                       ignored, so a half-set variable can never destroy data.
#                       ⚠️  It runs on EVERY container start while it is set:
#                       unset it (or drop it from your deploy config) as soon as
#                       the first boot finishes, or the next restart wipes the
#                       instance again. For a one-shot wipe prefer an ephemeral
#                       container:
#                           docker run --rm -e DRAN_RESET=wipe <image>
set -e

if [ -n "$DRAN_RESET" ]; then
  if [ "$DRAN_RESET" = "wipe" ]; then
    echo "[entrypoint] ⚠️  DRAN_RESET=wipe — DESTROYING all instance data and re-running setup."
    echo "[entrypoint] ⚠️  Unset DRAN_RESET now, or the next container start will wipe again."
    bin/dran eval "Dran.Release.reset"
  else
    echo "[entrypoint] DRAN_RESET is set to '$DRAN_RESET' but the only accepted value is 'wipe' — ignoring."
  fi
fi

if [ "$SKIP_MIGRATIONS" = "1" ]; then
  echo "[entrypoint] SKIP_MIGRATIONS=1, skipping setup."
else
  echo "[entrypoint] running setup (create DB → migrate → seed → backfill)..."
  bin/dran eval "Dran.Release.setup"
fi

echo "[entrypoint] starting dran release..."
exec bin/dran start
