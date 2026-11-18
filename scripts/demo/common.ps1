# Fonctions partagées par les scripts de démonstration (PowerShell 7+ recommandé : winget install Microsoft.PowerShell)

function Get-ResaflowUrl {
    param([Parameter(Mandatory)][string]$Namespace)
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"   # PS 5.1 : stderr natif = exception sinon
    $hostName = kubectl get ingressroute resaflow -n $Namespace -o jsonpath='{.spec.routes[0].match}' 2>$null
    $local = kubectl get svc resaflow-api-local -n $Namespace --ignore-not-found -o name 2>$null
    $ErrorActionPreference = $old
    if (-not $hostName) {
        # Cluster local (Docker Desktop) : pas d'Ingress, l'API est exposée par un Service LoadBalancer
        if ($local) { return "http://localhost:8000" }
        throw "IngressRoute introuvable dans $Namespace (application déployée ?)"
    }
    $hostName = ($hostName -split '`')[1]
    return "https://$hostName"
}

# Sonde de disponibilité en arrière-plan : une requête toutes les 200 ms, compte les échecs.
function Start-AvailabilityProbe {
    param([Parameter(Mandatory)][string]$Url, [int]$Seconds = 120)
    Start-Job -ArgumentList $Url, $Seconds -ScriptBlock {
        param($Url, $Seconds)
        $ok = 0; $ko = 0; $errors = @()
        $end = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $end) {
            try {
                $r = Invoke-WebRequest -Uri "$Url/api/v1/resources" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
                $ok++
            } catch {
                $code = $_.Exception.Response.StatusCode.value__
                if ($code -eq 401) { $ok++ }   # 401 = API vivante (route protégée sans jeton)
                else { $ko++; $errors += "$(Get-Date -Format HH:mm:ss.fff) $code $($_.Exception.Message)" }
            }
            Start-Sleep -Milliseconds 200
        }
        [pscustomobject]@{ Total = $ok + $ko; Echecs = $ko; Disponibilite = if ($ok + $ko) { [math]::Round(100 * $ok / ($ok + $ko), 3) } else { 0 }; Erreurs = $errors }
    }
}

function Show-ProbeResult {
    param([Parameter(Mandatory)]$Job)
    $result = Receive-Job -Job $Job -Wait -AutoRemoveJob
    Write-Host ""
    Write-Host ("Requêtes : {0} | Échecs : {1} | Disponibilité mesurée : {2} %" -f $result.Total, $result.Echecs, $result.Disponibilite) -ForegroundColor Cyan
    if ($result.Erreurs) { $result.Erreurs | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow } }
    return $result
}
