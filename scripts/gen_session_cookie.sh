#!/bin/bash
# Obtain a live Dran session cookie via the real login flow (curl).
# Writes the cookie value to /tmp/dran_cookie.txt for use by scripts/screenshot.sh.
# Requires the dev server running on :4000 and admin credentials (default admin/dran).
set -e

JAR=$(mktemp /tmp/dran-jar.XXXXXX)
BASE="${DRAN_URL:-http://localhost:4000}"
USER="${DRAN_USER:-admin}"
PASS="${DRAN_PASS:-dran}"

CSRF=$(curl -s -c "$JAR" "$BASE/login" | grep -oE 'name="_csrf_token" value="[^"]*"' | head -1 | sed 's/.*value="//;s/"$//')
if [ -z "$CSRF" ]; then
  echo "ERROR: could not fetch CSRF token from $BASE/login" >&2
  exit 1
fi

CODE=$(curl -s -b "$JAR" -c "$JAR" -X POST "$BASE/session" \
  --data-urlencode "_csrf_token=$CSRF" \
  --data-urlencode "login[username]=$USER" \
  --data-urlencode "login[password]=$PASS" \
  -o /dev/null -w "%{http_code}")

if [ "$CODE" != "302" ]; then
  echo "ERROR: login failed (HTTP $CODE)" >&2
  exit 1
fi

grep "_dran_key" "$JAR" | awk '{print $7}' > /tmp/dran_cookie.txt
rm -f "$JAR"
echo "cookie written to /tmp/dran_cookie.txt"
