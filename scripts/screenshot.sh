#!/bin/bash
# Capture Dran UI screenshots into docs/screenshots/.
# Prerequisites:
#   1. Dev server running on :4000
#   2. Session cookie: scripts/gen_session_cookie.sh
#   3. Node deps:   cd scripts/screenshot && npm install   (one-time)
#      Uses playwright-core + the ms-playwright chromium cache (no browser download).
set -e
cd "$(dirname "$0")/.."

if [ ! -s /tmp/dran_cookie.txt ]; then
  scripts/gen_session_cookie.sh
fi

node scripts/screenshot/shoot.js
echo "screenshots updated in docs/screenshots/"
