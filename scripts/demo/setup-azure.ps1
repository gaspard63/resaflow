<#
.SYNOPSIS
  Provisionne TOUTE la plateforme ResaFlow depuis zéro (reproductibilité de l'IaC).
.DESCRIPTION
  Étapes : bootstrap de l'état Terraform -> stack azure -> stack platform -> variables GitHub.
  Prérequis (Windows) :
    winget install Microsoft.AzureCLI Hashicorp.Terraform Kubernetes.kubectl Helm.Helm GitHub.cli
    az aks install-cli   # installe kubelogin
    az login ; gh auth login
.EXAMPLE
  ./scripts/demo/setup-azure.ps1 -Suffix gs26 -GithubRepo moncompte/resaflow -Email moi@exemple.fr
#>
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{3,6}$')][string]$Suffix,
    [Parameter(Mandatory)][string]$GithubRepo,
    [Parameter(Mandatory)][string]$Email,
    [int]$Budget = 100
)
$ErrorActionPreference = "Stop"
# PowerShell 5.1 ne s'arrête pas quand un exécutable externe (terraform, az, gh) échoue :
# chaque appel est vérifié par son code de retour.
function Invoke-Checked([string]$What, [scriptblock]$Cmd) {
    & $Cmd
    if ($LASTEXITCODE -ne 0) { throw "Échec : $What (code $LASTEXITCODE). Corrigez puis relancez le script : il reprend l'existant." }
}
$root = Resolve-Path "$PSScriptRoot/../.."
$tf = Join-Path $root "infra/terraform"
$me = az ad signed-in-user show --query id -o tsv

Write-Host "=== 1/4 Bootstrap de l'état Terraform ===" -ForegroundColor Magenta
Push-Location "$tf/bootstrap"
Invoke-Checked "init bootstrap" { terraform init -input=false }
Invoke-Checked "apply bootstrap" { terraform apply -auto-approve "-var=suffix=$Suffix" }
$backend = terraform output -raw backend_hcl
$stateId = terraform output -raw tfstate_storage_account_id
Pop-Location
Set-Content -Path "$tf/azure/backend.hcl" -Value $backend
Set-Content -Path "$tf/platform/backend.hcl" -Value $backend

Write-Host "=== 2/4 Stack azure (réseau, AKS, ACR, PostgreSQL, Blob, Key Vault, identités, budget) ===" -ForegroundColor Magenta
@"
suffix                     = "$Suffix"
github_repository          = "$GithubRepo"
admin_object_ids           = ["$me"]
tfstate_storage_account_id = "$stateId"
budget_amount              = $Budget
budget_contact_emails      = ["$Email"]
budget_start_date          = "$((Get-Date -Day 1).ToString('yyyy-MM-01'))T00:00:00Z"
"@ | Set-Content "$tf/azure/terraform.tfvars"
Push-Location "$tf/azure"
Invoke-Checked "init azure" { terraform init -input=false -reconfigure "-backend-config=backend.hcl" "-backend-config=key=azure.tfstate" }
Invoke-Checked "apply azure" { terraform apply -auto-approve }
$out = terraform output -json | ConvertFrom-Json
Pop-Location

Write-Host "=== 3/4 Stack platform (namespaces, Traefik, cert-manager, Prometheus, Grafana, Loki, Tempo) ===" -ForegroundColor Magenta
@"
resource_group            = "$($out.resource_group.value)"
aks_name                  = "$($out.aks_name.value)"
deploy_identity_object_id = "$($out.github_deploy_principal_id.value)"
acme_email                = "$Email"
"@ | Set-Content "$tf/platform/terraform.tfvars"
Invoke-Checked "get-credentials" { az aks get-credentials -g $out.resource_group.value -n $out.aks_name.value --overwrite-existing }
Invoke-Checked "kubelogin" { kubelogin convert-kubeconfig -l azurecli }
Push-Location "$tf/platform"
Invoke-Checked "init platform" { terraform init -input=false -reconfigure "-backend-config=backend.hcl" "-backend-config=key=platform.tfstate" }
Invoke-Checked "apply platform" { terraform apply -auto-approve }
$ip = terraform output -raw ingress_public_ip
Pop-Location

Write-Host "=== 4/4 Variables GitHub Actions (aucun secret : fédération OIDC) ===" -ForegroundColor Magenta
$vars = $out.github_actions_variables.value
$vars.PSObject.Properties | ForEach-Object { gh variable set $_.Name --repo $GithubRepo --body $_.Value }
gh variable set INGRESS_IP --repo $GithubRepo --body $ip
gh variable set TF_BACKEND_HCL --repo $GithubRepo --body $backend
gh variable set TF_VARS_AZURE --repo $GithubRepo --body (Get-Content "$tf/azure/terraform.tfvars" -Raw)
gh variable set TF_VARS_PLATFORM --repo $GithubRepo --body (Get-Content "$tf/platform/terraform.tfvars" -Raw)
foreach ($envName in "dev", "staging", "production", "infra") {
    gh api --method PUT "repos/$GithubRepo/environments/$envName" | Out-Null
}
Write-Host @"

Plateforme prête. Étapes restantes (interface GitHub, Settings > Environments) :
  - "production" et "infra" : ajouter "Required reviewers" (approbation manuelle)
  - Pousser sur main : le pipeline construit, scanne, publie et déploie dev -> staging -> prod (canary)

URLs (après le premier déploiement) :
  https://resaflow-dev.$($ip -replace '\.','-').sslip.io
  https://resaflow-staging.$($ip -replace '\.','-').sslip.io
  https://resaflow-prod.$($ip -replace '\.','-').sslip.io
Grafana : kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
  mot de passe : terraform -chdir=infra/terraform/platform output -raw grafana_admin_password
"@ -ForegroundColor Green
