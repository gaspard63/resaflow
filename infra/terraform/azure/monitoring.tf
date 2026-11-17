# Journalisation de sécurité côté plateforme Azure (A.8.15) : audit du plan de contrôle Kubernetes,
# accès aux secrets, connexions à la base et accès au stockage, centralisés dans Log Analytics.
# La supervision applicative (métriques, logs, traces) est assurée in-cluster (stack plateforme).

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${local.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  daily_quota_gb      = 1 # FinOps : plafond d'ingestion quotidienne
  tags                = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "aks-audit"
  target_resource_id         = azurerm_kubernetes_cluster.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log { category = "kube-audit-admin" } # écritures uniquement : bien moins volumineux que kube-audit
  enabled_log { category = "guard" }            # authentifications Entra ID
}

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "kv-audit"
  target_resource_id         = azurerm_key_vault.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log { category = "AuditEvent" }
}

resource "azurerm_monitor_diagnostic_setting" "postgres" {
  name                       = "psql-logs"
  target_resource_id         = azurerm_postgresql_flexible_server.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log { category = "PostgreSQLLogs" }
}

resource "azurerm_monitor_diagnostic_setting" "blob" {
  name                       = "blob-audit"
  target_resource_id         = "${azurerm_storage_account.main.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log { category = "StorageWrite" }
  enabled_log { category = "StorageDelete" }
}
