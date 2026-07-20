#!/bin/sh
# Dran container entrypoint.
#
# Runs pending DB migrations before starting the Phoenix release. A failed
# migration aborts boot (Coolify rolls back) instead of serving against an
# un-migrated schema. Set SKIP_MIGRATIONS=1 to bypass (one-off task containers).
set -e

if [ "$SKIP_MIGRATIONS" = "1" ]; then
  echo "[entrypoint] SKIP_MIGRATIONS=1, skipping migrations."
else
  echo "[entrypoint] running pending migrations..."
  bin/dran eval "Dran.Release.migrate"
fi

echo "[entrypoint] starting dran release..."
exec bin/dran start
