<#
.SYNOPSIS
  Déploie ResaFlow sur le Kubernetes LOCAL de Docker Desktop, avec Prometheus, Grafana et Alertmanager.
.DESCRIPTION
  Plan de repli quand l'abonnement Azure for Students n'a pas de quota de vCPU pour AKS.
  Même chart Helm qu'en production : HPA, PDB, StatefulSets sur volumes persistants, sondes, ServiceMonitor,
  PrometheusRule (SLO et alertes) et tableaux de bord Grafana. Key Vault est remplacé par un Secret Kubernetes,
  Blob Storage par Azurite, l'Ingress par un Service LoadBalancer (http://localhost:8000 pour l'API).
  Prérequis : Docker Desktop avec Kubernetes activé, kubectl, helm ; `docker compose down` (ports 8000/8080 libres).
.EXAMPLE
  ./scripts/demo/setup-local-k8s.ps1
#>
param([string]$Namespace = "resaflow-staging")
$ErrorActionPreference = "Stop"
function Invoke-Checked([string]$What, [scriptblock]$Cmd) {
    & $Cmd
    if ($LASTEXITCODE -ne 0) { throw "Échec : $What (code $LASTEXITCODE). Corrigez puis relancez le script." }
}
function Get-ReleaseStatus([string]$Release, [string]$Ns) {
    # PowerShell 5.1 : une sortie d'erreur d'un exécutable externe devient une exception avec "Stop"
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $json = helm status $Release -n $Ns -o json 2>$null
    $code = $LASTEXITCODE; $ErrorActionPreference = $old
    if ($code -eq 0 -and $json) { return (($json | Out-String) | ConvertFrom-Json).info.status }
    return $null
}
$root = Resolve-Path "$PSScriptRoot/../.."
Set-Location $root

Write-Host "=== 1/5 Contexte Kubernetes : docker-desktop ===" -ForegroundColor Magenta
Invoke-Checked "contexte docker-desktop" { kubectl config use-context docker-desktop }
Invoke-Checked "nœud prêt" { kubectl wait --for=condition=Ready node --all --timeout=120s }

Write-Host "=== 2/5 metrics-server (nécessaire à l'HPA) ===" -ForegroundColor Magenta
Invoke-Checked "metrics-server" { kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml }
$patch = Join-Path $env:TEMP "metrics-server-patch.json"
Set-Content -Path $patch -Encoding Ascii -Value '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
$args0 = kubectl get deployment metrics-server -n kube-system -o jsonpath='{.spec.template.spec.containers[0].args}'
if ($args0 -notmatch "insecure") { Invoke-Checked "patch metrics-server" { kubectl patch deployment metrics-server -n kube-system --type=json --patch-file $patch } }

Write-Host "=== 3/5 Supervision : kube-prometheus-stack (Prometheus, Alertmanager, Grafana) ===" -ForegroundColor Magenta
Invoke-Checked "helm repo" { helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update }
# Une installation interrompue laisse la release « pending » et bloque toute nouvelle tentative : on la nettoie
$kpsStatus = Get-ReleaseStatus "kube-prometheus-stack" "monitoring"
if ($kpsStatus -like "pending*") {
    Write-Host "  release bloquée ($kpsStatus) : désinstallation avant reprise" -ForegroundColor Yellow
    Invoke-Checked "nettoyage kube-prometheus-stack" { helm uninstall kube-prometheus-stack -n monitoring --wait }
}
Invoke-Checked "kube-prometheus-stack" { helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 92.3.1 -n monitoring --create-namespace -f deploy/local/kps-values.yaml --wait --timeout 15m }

Write-Host "=== 4/5 Secrets locaux et images ===" -ForegroundColor Magenta
$secrets = "deploy/helm/resaflow/secrets.local.yaml"
if (-not (Test-Path $secrets)) {
    function New-Pwd([int]$n) { -join ((48..57) + (65..90) + (97..122) | Get-Random -Count $n | ForEach-Object { [char]$_ }) }
    $pg = New-Pwd 24; $rb = New-Pwd 24; $jwt = New-Pwd 48; $admin = New-Pwd 16
    $text = (Get-Content "deploy/helm/resaflow/secrets.local.example.yaml" -Raw)
    $text = $text -replace 'POSTGRES_PASSWORD: change-me', "POSTGRES_PASSWORD: $pg" `
                  -replace 'RABBITMQ_PASSWORD: change-me', "RABBITMQ_PASSWORD: $rb" `
                  -replace 'resaflow:change-me@resaflow-postgresql', "resaflow:$pg@resaflow-postgresql" `
                  -replace 'resaflow:change-me@resaflow-rabbitmq', "resaflow:$rb@resaflow-rabbitmq" `
                  -replace 'JWT_SECRET: change-me-with-a-long-random-string-of-48-chars', "JWT_SECRET: $jwt" `
                  -replace 'ADMIN_PASSWORD: change-me-admin', "ADMIN_PASSWORD: $admin"
    [IO.File]::WriteAllText((Join-Path $root $secrets), $text)
    Write-Host "  secrets.local.yaml créé (mot de passe admin : $admin)" -ForegroundColor Yellow
}
Invoke-Checked "images" { docker compose build }

Write-Host "=== 5/5 ResaFlow (chart Helm, valeurs staging) dans $Namespace ===" -ForegroundColor Magenta
$rfStatus = Get-ReleaseStatus "resaflow" $Namespace
if ($rfStatus -like "pending*") { Invoke-Checked "nettoyage resaflow" { helm uninstall resaflow -n $Namespace --wait } }
Invoke-Checked "helm resaflow" { helm upgrade --install resaflow deploy/helm/resaflow -n $Namespace --create-namespace -f deploy/helm/resaflow/values-staging.yaml -f $secrets --set monitoring.enabled=true --set monitoring.dashboards=true --wait --timeout 15m }
$svc = kubectl get svc resaflow-api-local -n $Namespace --ignore-not-found -o name
if (-not $svc) {
    Invoke-Checked "service API local" { kubectl expose deployment resaflow-api -n $Namespace --name resaflow-api-local --type LoadBalancer --port 8000 --target-port 8000 }
}
kubectl get pods,svc,hpa,pvc -n $Namespace
Write-Host @"

ResaFlow tourne sur Kubernetes (Docker Desktop), namespace $Namespace.
  API (répartie sur tous les pods) : http://localhost:8000/api/docs
  Grafana : kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80   (admin / resaflow-local)
  Alertmanager : kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
Démonstrations : ./scripts/demo/demo-hpa.ps1 , demo-resilience.ps1 , demo-rolling-update.ps1
"@ -ForegroundColor Green
