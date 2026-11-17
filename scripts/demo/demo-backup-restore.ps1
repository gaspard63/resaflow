<#
.SYNOPSIS
  Sauvegarde manuelle de la base vers Blob Storage, puis test de restauration (A.8.13).
.DESCRIPTION
  1. Lance immédiatement le CronJob de sauvegarde
  2. Liste les sauvegardes présentes dans le conteneur backups-<env>
  3. (option -TestRestore) restaure la dernière sauvegarde dans une base temporaire et compte les lignes
  Prérequis : az login, kubectl configuré, rôle "Storage Blob Data Reader" sur le compte de stockage.
.EXAMPLE
  ./scripts/demo/demo-backup-restore.ps1 -Environment staging -StorageAccount stresaflowgs26 -TestRestore
#>
param(
    [string]$Environment = "staging",
    [Parameter(Mandatory)][string]$StorageAccount,
    [switch]$TestRestore
)
$ErrorActionPreference = "Stop"
$ns = "resaflow-$Environment"
$job = "backup-manual-$(Get-Date -Format yyyyMMddHHmmss)"

Write-Host "1. Sauvegarde à la demande" -ForegroundColor Magenta
kubectl create job $job --from=cronjob/resaflow-db-backup -n $ns
kubectl wait --for=condition=complete job/$job -n $ns --timeout=600s
kubectl logs job/$job -n $ns -c upload

Write-Host "`n2. Sauvegardes présentes dans backups-$Environment" -ForegroundColor Magenta
az storage blob list --account-name $StorageAccount --container-name "backups-$Environment" --auth-mode login `
  --query "sort_by([], &properties.lastModified)[].{nom:name, taille:properties.contentLength, tier:properties.blobTier, date:properties.lastModified}" -o table

if ($TestRestore) {
    Write-Host "`n3. Test de restauration dans une base temporaire" -ForegroundColor Magenta
    $latest = az storage blob list --account-name $StorageAccount --container-name "backups-$Environment" --auth-mode login `
      --query "sort_by([], &properties.lastModified)[-1].name" -o tsv
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "resaflow-restore.sql.gz"
    az storage blob download --account-name $StorageAccount --container-name "backups-$Environment" --name $latest --file $tmp --auth-mode login | Out-Null
    docker run -d --rm --name resaflow-restore -e POSTGRES_PASSWORD=restore -e POSTGRES_DB=restore postgres:17-alpine | Out-Null
    Start-Sleep -Seconds 8
    docker cp $tmp resaflow-restore:/tmp/dump.sql.gz
    docker exec resaflow-restore sh -c "gunzip -c /tmp/dump.sql.gz | psql -q -U postgres -d restore" | Out-Null
    docker exec resaflow-restore psql -U postgres -d restore -c "SELECT (SELECT count(*) FROM users) AS utilisateurs, (SELECT count(*) FROM resources) AS ressources, (SELECT count(*) FROM reservations) AS reservations;"
    docker stop resaflow-restore | Out-Null
    Remove-Item $tmp
    Write-Host "Restauration vérifiée à partir de $latest" -ForegroundColor Green
}
