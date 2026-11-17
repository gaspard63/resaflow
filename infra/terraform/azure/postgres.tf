# Base de production : Azure Database for PostgreSQL Flexible Server
# - réseau privé uniquement (sous-réseau délégué + zone DNS privée), aucun accès public
# - chiffrement au repos (clés gérées par la plateforme) et TLS obligatoire en transit (A.8.24)
# - sauvegardes automatiques avec restauration à un instant donné sur 7 jours (A.8.13)
# Les environnements dev/staging utilisent un PostgreSQL in-cluster sur PersistentVolume (arbitrage FinOps).

resource "azurerm_private_dns_zone" "postgres" {
  name                = "${local.name}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "postgres-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  resource_group_name   = azurerm_resource_group.main.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

resource "random_password" "postgres_admin" {
  length           = 32
  special          = true
  override_special = "-_~" # caractères sûrs dans une URL de connexion
}

resource "azurerm_postgresql_flexible_server" "main" {
  name                          = "psql-${local.name}"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  version                       = "17"
  sku_name                      = var.postgres_sku
  storage_mb                    = 32768
  storage_tier                  = "P4"
  auto_grow_enabled             = true
  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false # arbitrage FinOps (documenté dans le rapport)
  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false
  administrator_login           = "resaflowadmin"
  administrator_password        = random_password.postgres_admin.result
  zone                          = "1"
  tags                          = var.tags

  maintenance_window {
    day_of_week  = 0
    start_hour   = 3
    start_minute = 0
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  lifecycle {
    prevent_destroy = false # passer à true pour une vraie production
    ignore_changes  = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "resaflow" {
  name      = "resaflow"
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "fr_FR.utf8"
}

# Paramètres de sécurité et de journalisation
resource "azurerm_postgresql_flexible_server_configuration" "settings" {
  for_each = {
    require_secure_transport   = "on" # refuse toute connexion non chiffrée
    ssl_min_protocol_version   = "TLSv1.2"
    log_connections            = "on" # A.8.15 : traçabilité des connexions
    log_disconnections         = "on"
    log_min_duration_statement = "500"        # requêtes lentes (> 500 ms) journalisées
    "azure.extensions"         = "BTREE_GIST" # requis par la contrainte anti-chevauchement des réservations
  }
  name      = each.key
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = each.value
}
