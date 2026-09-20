#!/bin/sh
# Dran container entrypoint.
#
# Runs Dran.Release.setup/0 (create DB if missing → migrate → seed the default
# context → production seed → backfill personal workspaces) before starting the
# Phoenix release. On a fresh database it creates the schema and the default
# context. On subsequent deploys it short-circuits (DB already exists) and only
# runs pending migrations.
#
# The production seed (priv/repo/seeds_prod.exs) is OPT-IN: it creates the
# instance owner only when DRAN_ADMIN_PASSWORD is set. Without it the first
# visitor gets the /setup screen. Demo content is NEVER seeded by a release —
# Dran.Release.seed_demo/0 refuses to run outside dev.
#
# Env vars:
#   SKIP_MIGRATIONS=1   bypass setup entirely (one-off task containers).
#   DRAN_RESET=1        DESTRUCTIVE: drop the whole database schema (every
#                       workspace with its content, every user, key and
#                       setting) and rebuild it empty. The instance comes back
#                       up at /setup — the first-run screen that creates the
#                       owner — so you onboard from scratch, and that flow gives
#                       the new owner its own personal workspace.
#                       The value must be exactly "1"; anything else is ignored,
#                       so a half-set variable can never destroy data.
#                       ⚠️  It runs on EVERY container start while it is set:
#                       unset it (or drop it from your deploy config) as soon as
#                       the first boot finishes, or the next restart wipes the
#                       instance again. For a one-shot wipe prefer an ephemeral
#                       container:
#                           docker run --rm -e DRAN_RESET=1 <image>
set -e

if [ -n "$DRAN_RESET" ]; then
  if [ "$DRAN_RESET" = "1" ]; then
    echo "[entrypoint] ⚠️  DRAN_RESET=1 — DESTROYING all instance data and re-running setup."
    echo "[entrypoint] ⚠️  Unset DRAN_RESET now, or the next container start will wipe again."
    bin/dran eval "Dran.Release.reset"
  else
    echo "[entrypoint] DRAN_RESET is set to '$DRAN_RESET' but only '1' triggers the reset — ignoring."
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
