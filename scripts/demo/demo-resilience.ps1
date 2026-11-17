<#
.SYNOPSIS
  Démonstration de résilience (grille : Orchestration — résilience testée).
.DESCRIPTION
  1. Supprime brutalement un pod API pendant qu'une sonde mesure la disponibilité
  2. Supprime TOUS les pods API d'un coup (pire cas) et mesure le temps de retour
  3. Tue le worker pendant la génération d'un export : la tâche est reprise (acks tardifs)
  4. Supprime le pod PostgreSQL in-cluster : les données survivent (PersistentVolume)
  Les résultats s'affichent à l'écran : faites des captures pour le rapport.
.EXAMPLE
  ./scripts/demo/demo-resilience.ps1 -Namespace resaflow-staging
#>
param([string]$Namespace = "resaflow-staging")
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/common.ps1"
$url = Get-ResaflowUrl -Namespace $Namespace
Write-Host "Application : $url" -ForegroundColor Green

# ---------------------------------------------------------------- 1. un pod API supprimé
Write-Host "`n=== 1. Suppression d'un pod API (les autres réplicas continuent de servir) ===" -ForegroundColor Magenta
kubectl get pods -n $Namespace -l app.kubernetes.io/component=api -o wide
$probe = Start-AvailabilityProbe -Url $url -Seconds 60
Start-Sleep -Seconds 5
$victim = kubectl get pods -n $Namespace -l "app.kubernetes.io/component=api" -o jsonpath='{.items[0].metadata.name}'
Write-Host "Suppression de $victim" -ForegroundColor Yellow
kubectl delete pod $victim -n $Namespace --grace-period=0 --force
kubectl get pods -n $Namespace -l app.kubernetes.io/component=api -w --request-timeout=40s 2>$null | Select-Object -First 8
Show-ProbeResult -Job $probe | Out-Null

# ---------------------------------------------------------------- 2. tous les pods API supprimés
Write-Host "`n=== 2. Suppression de TOUS les pods API (le Deployment les recrée) ===" -ForegroundColor Magenta
$sw = [Diagnostics.Stopwatch]::StartNew()
kubectl delete pods -n $Namespace -l app.kubernetes.io/component=api --wait=false
kubectl rollout status deployment/resaflow-api -n $Namespace --timeout=180s
$sw.Stop()
Write-Host ("Retour à l'état nominal en {0:N1} s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Cyan

# ---------------------------------------------------------------- 3. worker tué pendant une tâche
Write-Host "`n=== 3. Worker supprimé pendant une tâche (reprise grâce à acks_late) ===" -ForegroundColor Magenta
Write-Host "Demandez un export PDF dans l'interface (onglet Exports PDF), puis appuyez sur Entrée immédiatement."
Read-Host | Out-Null
kubectl delete pods -n $Namespace -l app.kubernetes.io/component=worker --grace-period=0 --force
kubectl rollout status deployment/resaflow-worker -n $Namespace --timeout=180s
Write-Host "Vérifiez dans l'interface que l'export passe à « Prêt » (message réattribué par RabbitMQ)." -ForegroundColor Cyan

# ---------------------------------------------------------------- 4. persistance de la base
$pg = kubectl get statefulset resaflow-postgresql -n $Namespace --ignore-not-found -o name
if ($pg) {
    Write-Host "`n=== 4. Suppression du pod PostgreSQL : les données survivent (PersistentVolume) ===" -ForegroundColor Magenta
    $count = "SELECT count(*) FROM reservations;"
    $before = kubectl exec -n $Namespace resaflow-postgresql-0 -- sh -c "psql -U resaflow -d resaflow -tAc '$count'"
    kubectl delete pod resaflow-postgresql-0 -n $Namespace
    kubectl wait --for=condition=Ready pod/resaflow-postgresql-0 -n $Namespace --timeout=180s
    $after = kubectl exec -n $Namespace resaflow-postgresql-0 -- sh -c "psql -U resaflow -d resaflow -tAc '$count'"
    Write-Host "Réservations avant : $before | après redémarrage : $after" -ForegroundColor Cyan
    kubectl get pvc -n $Namespace
}
Write-Host "`nDémonstration terminée." -ForegroundColor Green
