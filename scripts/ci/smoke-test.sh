#!/usr/bin/env bash
# Tests de fumée post-déploiement : front servi, API prête, authentification fonctionnelle.
# Usage : smoke-test.sh <url_de_base> [en-tête supplémentaire, ex. "X-Canary: always"]
set -euo pipefail

BASE="${1%/}"; EXTRA_HEADER="${2:-X-Smoke: 1}"
CURL=(curl -fsS --retry 10 --retry-delay 6 --retry-all-errors --max-time 15 -H "$EXTRA_HEADER")

echo "1/4 front-end"
"${CURL[@]}" "$BASE/" | grep -q '<div id="root">'

echo "2/4 en-têtes de sécurité (HSTS, nosniff)"
HEADERS="$("${CURL[@]}" -D - -o /dev/null "$BASE/")"
grep -qi '^strict-transport-security:' <<<"$HEADERS"
grep -qi '^x-content-type-options: nosniff' <<<"$HEADERS"

echo "3/4 API : route protégée sans jeton -> 401"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "$EXTRA_HEADER" "$BASE/api/v1/resources")"
[[ "$CODE" == "401" ]] || { echo "attendu 401, obtenu $CODE" >&2; exit 1; }

echo "4/4 API : inscription + connexion + liste des ressources"
EMAIL="smoke-$(date +%s)-$RANDOM@example.com"; PASS="smoke-$(openssl rand -hex 12)"
"${CURL[@]}" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"full_name\":\"Smoke Test\",\"password\":\"$PASS\"}" "$BASE/api/v1/auth/register" >/dev/null
TOKEN="$("${CURL[@]}" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" "$BASE/api/v1/auth/login" | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')"
"${CURL[@]}" -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/resources" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert isinstance(d, list)'

echo "Tests de fumée OK"
