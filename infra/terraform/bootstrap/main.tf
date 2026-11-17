# Amorçage (exécuté UNE fois, état local) : compte de stockage qui héberge l'état Terraform distant
# des deux autres stacks. Chiffré, versionné, sans accès anonyme ni clé partagée (Entra ID uniquement).
#
#   cd infra/terraform/bootstrap
#   terraform init ; terraform apply -var="suffix=<3-6 caractères uniques>"
#   -> recopier la sortie backend_hcl dans ../azure/backend.hcl et ../platform/backend.hcl

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.81" }
  }
}

provider "azurerm" {
  features {}
  storage_use_azuread = true
}

variable "location" {
  type    = string
  default = "francecentral"
}

variable "suffix" {
  description = "Suffixe unique (noms de comptes de stockage globaux)"
  type        = string
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "tfstate" {
  name     = "rg-resaflow-tfstate"
  location = var.location
  tags     = { project = "resaflow", purpose = "terraform-state", managed_by = "terraform" }
}

resource "azurerm_storage_account" "tfstate" {
  name                              = "sttfresaflow${var.suffix}"
  resource_group_name               = azurerm_resource_group.tfstate.name
  location                          = azurerm_resource_group.tfstate.location
  account_tier                      = "Standard"
  account_replication_type          = "LRS"
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  allow_nested_items_to_be_public   = false
  shared_access_key_enabled         = false
  default_to_oauth_authentication   = true
  infrastructure_encryption_enabled = true

  blob_properties {
    versioning_enabled = true # historique de l'état : retour arrière possible
    delete_retention_policy {
      days = 30
    }
    container_delete_retention_policy {
      days = 30
    }
  }
  tags = azurerm_resource_group.tfstate.tags
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# L'identité qui exécute Terraform (vous, puis la CI) doit pouvoir lire/écrire l'état
resource "azurerm_role_assignment" "tfstate_current" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

output "backend_hcl" {
  value = <<-EOT
    resource_group_name  = "${azurerm_resource_group.tfstate.name}"
    storage_account_name = "${azurerm_storage_account.tfstate.name}"
    container_name       = "tfstate"
    use_azuread_auth     = true
  EOT
}

output "tfstate_storage_account_id" {
  value = azurerm_storage_account.tfstate.id
}
