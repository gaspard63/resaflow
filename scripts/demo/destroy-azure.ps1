<#
.SYNOPSIS
  Détruit la plateforme (dans l'ordre inverse) pour ne plus rien payer — et prouver la reproductibilité
  en la recréant ensuite avec setup-azure.ps1.
#>
$ErrorActionPreference = "Stop"
$tf = Resolve-Path "$PSScriptRoot/../../infra/terraform"
foreach ($stack in "platform", "azure") {
    Write-Host "=== destroy $stack ===" -ForegroundColor Magenta
    Push-Location "$tf/$stack"
    terraform destroy -auto-approve
    Pop-Location
}
Write-Host "Le compte de stockage de l'état (bootstrap) est conservé ; pour le supprimer : terraform -chdir=$tf/bootstrap destroy" -ForegroundColor Yellow
Write-Host "Key Vault est en suppression réversible 7 jours (purge protégée) : changez de suffixe pour recréer immédiatement." -ForegroundColor Yellow
