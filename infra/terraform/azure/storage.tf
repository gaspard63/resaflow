# Stockage objet : fichiers téléversés, exports PDF, sauvegardes de base.
# - accès par Entra ID uniquement (clés partagées désactivées), aucun conteneur public
# - double chiffrement au repos (service + infrastructure), TLS 1.2 minimum (A.8.24)
# - versionnage + corbeille 7 jours (protection contre l'effacement accidentel ou malveillant)

resource "azurerm_storage_account" "main" {
  name                              = "st${local.flat}"
  resource_group_name               = azurerm_resource_group.main.name
  location                          = azurerm_resource_group.main.location
  account_kind                      = "StorageV2"
  account_tier                      = "Standard"
  account_replication_type          = "LRS" # FinOps ; ZRS/GRS pour une vraie production
  access_tier                       = "Hot"
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  allow_nested_items_to_be_public   = false
  shared_access_key_enabled         = false
  default_to_oauth_authentication   = true
  infrastructure_encryption_enabled = true
  local_user_enabled                = false
  sftp_enabled                      = false
  public_network_access_enabled     = !var.enable_private_endpoints
  tags                              = var.tags

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }
}

# Un jeu de conteneurs par environnement : l'identité de dev ne peut pas lire les fichiers de prod (A.8.31)
locals {
  containers = { for pair in setproduct(["uploads", "exports", "backups"], var.environments) :
  "${pair[0]}-${pair[1]}" => { kind = pair[0], env = pair[1] } }
}

resource "azurerm_storage_container" "containers" {
  for_each              = local.containers
  name                  = each.key
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

# FinOps : cycle de vie automatique des objets
resource "azurerm_storage_management_policy" "lifecycle" {
  storage_account_id = azurerm_storage_account.main.id

  rule {
    name    = "backups-cool-then-delete"
    enabled = true
    filters {
      blob_types   = ["blockBlob"]
      prefix_match = [for e in var.environments : "backups-${e}/"]
    }
    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than = 7  # -50 % environ sur le stockage
        delete_after_days_since_modification_greater_than       = 30 # rétention 30 jours
      }
      version {
        delete_after_days_since_creation = 7
      }
    }
  }

  rule {
    name    = "exports-expire"
    enabled = true
    filters {
      blob_types   = ["blockBlob"]
      prefix_match = [for e in var.environments : "exports-${e}/"]
    }
    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = 8 # filet de sécurité derrière la purge applicative (7 j)
      }
      version {
        delete_after_days_since_creation = 1
      }
    }
  }

  rule {
    name    = "old-versions"
    enabled = true
    filters {
      blob_types   = ["blockBlob"]
      prefix_match = [for e in var.environments : "uploads-${e}/"]
    }
    actions {
      version {
        delete_after_days_since_creation = 30
      }
    }
  }
}

# Point de terminaison privé (optionnel) : le trafic Blob ne quitte pas le VNet
resource "azurerm_private_dns_zone" "blob" {
  count               = var.enable_private_endpoints ? 1 : 0
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  count                 = var.enable_private_endpoints ? 1 : 0
  name                  = "blob-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.blob[0].name
  resource_group_name   = azurerm_resource_group.main.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

resource "azurerm_private_endpoint" "blob" {
  count               = var.enable_private_endpoints ? 1 : 0
  name                = "pe-blob-${local.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.endpoints.id
  tags                = var.tags

  private_service_connection {
    name                           = "blob"
    private_connection_resource_id = azurerm_storage_account.main.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob[0].id]
  }
}
