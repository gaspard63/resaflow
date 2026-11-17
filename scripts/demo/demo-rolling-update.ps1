<#
.SYNOPSIS
  Démonstration d'un rolling update sans interruption, puis d'un retour arrière (helm rollback).
.DESCRIPTION
  Redéploie l'API avec une nouvelle révision (changement de configuration qui force le renouvellement
  des pods) pendant qu'une sonde mesure la disponibilité. Attendu : 0 échec grâce à
  maxUnavailable=0, readinessProbe, preStop et PodDisruptionBudget.
.EXAMPLE
  ./scripts/demo/demo-rolling-update.ps1 -Namespace resaflow-staging
#>
param([string]$Namespace = "resaflow-staging")
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/common.ps1"
$url = Get-ResaflowUrl -Namespace $Namespace

Write-Host "Historique des révisions :" -ForegroundColor Green
helm history resaflow -n $Namespace --max 5

$probe = Start-AvailabilityProbe -Url $url -Seconds 150
Start-Sleep -Seconds 5
Write-Host "`nRolling update (renouvellement de tous les pods API)…" -ForegroundColor Magenta
kubectl rollout restart deployment/resaflow-api -n $Namespace
kubectl rollout status deployment/resaflow-api -n $Namespace --timeout=300s
Write-Host "`nRetour arrière Helm vers la révision précédente…" -ForegroundColor Magenta
helm rollback resaflow 0 -n $Namespace --wait --timeout 5m
$r = Show-ProbeResult -Job $probe
kubectl rollout history deployment/resaflow-api -n $Namespace
if ($r.Echecs -eq 0) { Write-Host "Aucune requête perdue pendant la mise à jour et le retour arrière." -ForegroundColor Green }
