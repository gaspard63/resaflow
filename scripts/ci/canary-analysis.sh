#!/usr/bin/env bash
# Analyse canary : génère du trafic puis compare le taux d'erreurs 5xx et la latence p95 du canary
# avec les seuils du SLO, à partir de Prometheus (port-forward, aucun service exposé publiquement).
#
# Usage : canary-analysis.sh <url_de_base> <namespace> [durée_secondes]
# Sortie : code 0 si le canary est sain, 1 sinon (le pipeline annule alors le canary).
# Prometheus est interrogé via le proxy de l'API Kubernetes (droit "services/proxy" limité à ce service).
set -euo pipefail

BASE="${1%/}"; NS="$2"; DURATION="${3:-300}"
MAX_ERROR_RATIO="${MAX_ERROR_RATIO:-0.01}"   # 1 % d'erreurs 5xx maximum
MAX_P95_SECONDS="${MAX_P95_SECONDS:-0.5}"    # p95 < 500 ms
MIN_REQUESTS="${MIN_REQUESTS:-50}"

# Compte de test (l'authentification passe par la version stable, le jeton est valable pour les deux)
EMAIL="canary-$(date +%s)@example.com"; PASS="canary-$(openssl rand -hex 12)"
curl -fsS -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"full_name\":\"Canary\",\"password\":\"$PASS\"}" "$BASE/api/v1/auth/register" >/dev/null
TOKEN="$(curl -fsS -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" \
  "$BASE/api/v1/auth/login" | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')"

echo "Génération de trafic vers le canary pendant ${DURATION}s…"
END=$((SECONDS + DURATION))
while (( SECONDS < END )); do
  for path in /api/v1/resources /api/v1/reservations /api/v1/exports /api/v1/auth/me; do
    curl -s -o /dev/null -H 'X-Canary: always' -H "Authorization: Bearer $TOKEN" "$BASE$path" || true
  done
  sleep 0.5
done
sleep 30   # laisse Prometheus collecter les derniers échantillons

PROM="/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query"
query() {
  local q
  q="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1], safe=""))' "$1")"
  kubectl get --raw "${PROM}?query=${q}" \
    | python3 -c 'import sys,json; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "0")'
}

SEL="namespace=\"${NS}\", resaflow_io_track=\"canary\", handler=~\"/api/.*\""
WINDOW="$((DURATION / 60 + 1))m"
TOTAL="$(query "sum(increase(http_requests_total{${SEL}}[${WINDOW}]))")"
ERRORS="$(query "sum(increase(http_requests_total{${SEL}, status=~\"5..\"}[${WINDOW}]))")"
P95="$(query "histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{${SEL}}[${WINDOW}])))")"

python3 - "$TOTAL" "$ERRORS" "$P95" "$MAX_ERROR_RATIO" "$MAX_P95_SECONDS" "$MIN_REQUESTS" <<'EOF'
import math, sys
total, errors, p95, max_err, max_p95, min_req = map(float, sys.argv[1:])
ratio = errors / total if total else 0.0
p95 = 0.0 if math.isnan(p95) else p95
print(f"Canary : {total:.0f} requêtes, {errors:.0f} erreurs 5xx ({ratio:.2%}), p95 = {p95*1000:.0f} ms")
ok = True
if total < min_req:
    print(f"ÉCHEC : trafic insuffisant pour conclure (< {min_req:.0f} requêtes)"); ok = False
if ratio > max_err:
    print(f"ÉCHEC : taux d'erreurs {ratio:.2%} > {max_err:.2%}"); ok = False
if p95 > max_p95:
    print(f"ÉCHEC : p95 {p95*1000:.0f} ms > {max_p95*1000:.0f} ms"); ok = False
print("Canary SAIN : promotion autorisée" if ok else "Canary REJETÉ : retour arrière")
sys.exit(0 if ok else 1)
EOF
