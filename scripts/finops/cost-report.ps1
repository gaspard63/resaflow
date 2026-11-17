<#
.SYNOPSIS
  Mesure FinOps : coût réel quotidien du groupe de ressources, par service Azure (API Cost Management).
.DESCRIPTION
  Exporte un CSV jour x service et affiche la moyenne journalière AVANT et APRÈS la date d'activation
  d'une optimisation. C'est la « mesure de l'effet » demandée par la grille.
  Les données de coût Azure arrivent avec 8 à 24 h de décalage.
.EXAMPLE
  ./scripts/finops/cost-report.ps1 -ResourceGroup rg-resaflow-gs26 -From 2026-10-20 -To 2026-11-20 -OptimizationDate 2026-11-03
#>
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][datetime]$From,
    [Parameter(Mandatory)][datetime]$To,
    [datetime]$OptimizationDate,
    [string]$OutFile = "finops-couts-quotidiens.csv"
)
$ErrorActionPreference = "Stop"
$sub = az account show --query id -o tsv
$scope = "/subscriptions/$sub/resourceGroups/$ResourceGroup"
$body = @{
    type       = "ActualCost"
    timeframe  = "Custom"
    timePeriod = @{ from = $From.ToString("yyyy-MM-ddT00:00:00Z"); to = $To.ToString("yyyy-MM-ddT23:59:59Z") }
    dataset    = @{
        granularity = "Daily"
        aggregation = @{ totalCost = @{ name = "Cost"; function = "Sum" } }
        grouping    = @(@{ type = "Dimension"; name = "ServiceName" })
    }
} | ConvertTo-Json -Depth 6 -Compress
$tmp = New-TemporaryFile
Set-Content -Path $tmp -Value $body
$res = az rest --method post --url "https://management.azure.com$scope/providers/Microsoft.CostManagement/query?api-version=2023-11-01" --body "@$tmp" | ConvertFrom-Json
Remove-Item $tmp

$cols = $res.properties.columns.name
$rows = foreach ($r in $res.properties.rows) {
    $o = [ordered]@{}
    for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $r[$i] }
    [pscustomobject]@{
        Date    = [datetime]::ParseExact("$($o.UsageDate)", "yyyyMMdd", $null)
        Service = $o.ServiceName
        Cout    = [math]::Round([double]$o.Cost, 4)
        Devise  = $o.Currency
    }
}
$rows | Sort-Object Date, Service | Export-Csv -Path $OutFile -NoTypeInformation -Encoding utf8
Write-Host "Export : $OutFile ($($rows.Count) lignes)" -ForegroundColor Green

$rows | Group-Object Service | ForEach-Object {
    [pscustomobject]@{ Service = $_.Name; Total = [math]::Round(($_.Group | Measure-Object Cout -Sum).Sum, 2) }
} | Sort-Object Total -Descending | Format-Table -AutoSize

if ($OptimizationDate) {
    $daily = $rows | Group-Object { $_.Date.ToString("yyyy-MM-dd") } | ForEach-Object {
        [pscustomobject]@{ Date = [datetime]$_.Name; Cout = ($_.Group | Measure-Object Cout -Sum).Sum }
    }
    $before = ($daily | Where-Object Date -lt $OptimizationDate | Measure-Object Cout -Average).Average
    $after = ($daily | Where-Object Date -ge $OptimizationDate | Measure-Object Cout -Average).Average
    Write-Host ("Coût moyen / jour avant : {0:N2} | après : {1:N2} | variation : {2:P1}" -f $before, $after, (($after - $before) / $before)) -ForegroundColor Cyan
    Write-Host ("Projection mensuelle avant : {0:N0} | après : {1:N0}" -f ($before * 30), ($after * 30)) -ForegroundColor Cyan
}
