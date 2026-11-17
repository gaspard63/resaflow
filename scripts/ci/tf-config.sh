#!/usr/bin/env bash
# Écrit backend.hcl et terraform.tfvars à partir de variables GitHub (contenu non secret :
# noms de ressources, identifiants d'objets). Les secrets sont générés par Terraform lui-même.
set -euo pipefail
cd infra/terraform
printf '%s\n' "${TF_BACKEND_HCL:?TF_BACKEND_HCL manquant}" | tee azure/backend.hcl > platform/backend.hcl
printf '%s\n' "${TF_VARS_AZURE:?TF_VARS_AZURE manquant}" > azure/terraform.tfvars
if [[ -n "${TF_VARS_PLATFORM:-}" ]]; then
  printf '%s\n' "$TF_VARS_PLATFORM" > platform/terraform.tfvars
fi
echo "Configuration Terraform écrite"
