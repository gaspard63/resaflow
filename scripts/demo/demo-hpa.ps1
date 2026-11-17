<#
.SYNOPSIS
  Démonstration de l'autoscaling horizontal du back-end (grille : Orchestration — scaling démontré).
.DESCRIPTION
  Lance un test de charge k6 (80 utilisateurs virtuels, 8 minutes) et affiche en parallèle l'évolution
  de l'HPA et des pods API. Prérequis : k6 (winget install k6 --source winget) et kubectl configuré.
  Pendant le test, ouvrez Grafana (dashboard "ResaFlow — Service API", panneau "Réplicas (HPA)").
.EXAMPLE
  ./scripts/demo/demo-hpa.ps1 -Namespace resaflow-staging -Vus 80 -Duration 8m
#>
param(
    [string]$Namespace = "resaflow-staging",
    [int]$Vus = 80,
    [string]$Duration = "8m"
)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/common.ps1"
$url = Get-ResaflowUrl -Namespace $Namespace
$root = Resolve-Path "$PSScriptRoot/../.."

Write-Host "État initial :" -ForegroundColor Green
kubectl get hpa -n $Namespace
kubectl top pods -n $Namespace -l app.kubernetes.io/component=api

$watch = Start-Job -ArgumentList $Namespace -ScriptBlock {
    param($ns)
    while ($true) {
        $line = kubectl get hpa resaflow-api -n $ns --no-headers 2>$null
        "$(Get-Date -Format HH:mm:ss)  $line"
        Start-Sleep -Seconds 15
    }
}

Write-Host "`nCharge : $Vus utilisateurs virtuels pendant $Duration sur $url" -ForegroundColor Magenta
k6 run -e BASE_URL=$url -e VUS=$Vus -e DURATION=$Duration --summary-export "$root/hpa-k6-summary.json" "$root/loadtest/k6-api.js"

Write-Host "`nÉvolution de l'HPA pendant le test (cible : 70 % CPU) :" -ForegroundColor Green
Receive-Job $watch
Stop-Job $watch; Remove-Job $watch
kubectl describe hpa resaflow-api -n $Namespace | Select-String -Pattern "Events" -Context 0, 15
Write-Host "`nLe retour au nombre minimal de pods intervient ~2 min après la fin de la charge (stabilizationWindowSeconds)." -ForegroundColor Cyan
