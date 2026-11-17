#!/usr/bin/env bash
# Déploie (ou met à jour) ResaFlow dans un environnement avec Helm.
#
# Usage : helm-deploy.sh <env> <image_tag> [options helm supplémentaires...]
# Variables attendues (GitHub Actions "vars") : ACR_LOGIN_SERVER, KEY_VAULT_NAME, AZURE_TENANT_ID,
#   STORAGE_ACCOUNT_URL, APP_IDENTITY_CLIENT_ID_<ENV>, INGRESS_IP (sortie ingress_public_ip de la stack
#   platform) et optionnellement OPERATORS_GROUP_ID et INGRESS_HOST (vrai nom de domaine).
set -euo pipefail

ENV="$1"; TAG="$2"; shift 2
NS="resaflow-${ENV}"
CHART="deploy/helm/resaflow"
ENV_UPPER="$(echo "$ENV" | tr '[:lower:]' '[:upper:]')"
CLIENT_ID_VAR="APP_IDENTITY_CLIENT_ID_${ENV_UPPER}"
CLIENT_ID="${!CLIENT_ID_VAR:?variable ${CLIENT_ID_VAR} manquante}"

# Nom d'hôte de démonstration : résolu par sslip.io vers l'IP publique de Traefik
INGRESS_IP="${INGRESS_IP:?variable INGRESS_IP manquante (sortie ingress_public_ip de la stack platform)}"
HOST="${INGRESS_HOST:-resaflow-${ENV}.${INGRESS_IP//./-}.sslip.io}"
echo "host=${HOST}" >> "${GITHUB_OUTPUT:-/dev/null}"

helm upgrade --install resaflow "$CHART" \
  --namespace "$NS" \
  -f "$CHART/values.yaml" -f "$CHART/values-${ENV}.yaml" \
  --set image.registry="${ACR_LOGIN_SERVER}" \
  --set image.tag="${TAG}" \
  --set keyVault.name="${KEY_VAULT_NAME}" \
  --set azure.tenantId="${AZURE_TENANT_ID}" \
  --set azure.workloadIdentityClientId="${CLIENT_ID}" \
  --set config.storageAccountUrl="${STORAGE_ACCOUNT_URL}" \
  --set ingress.host="${HOST}" \
  --set rbac.operatorsGroupObjectId="${OPERATORS_GROUP_ID:-}" \
  --wait --timeout 10m \
  --history-max 10 \
  "$@"

echo "Déployé : https://${HOST} (tag ${TAG})"
