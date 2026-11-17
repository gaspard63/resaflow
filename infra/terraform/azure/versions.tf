terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.81" }
    random  = { source = "hashicorp/random", version = "~> 3.7" }
  }

  # Configuration partielle : terraform init -backend-config=backend.hcl -backend-config="key=azure.tfstate"
  backend "azurerm" {}
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false # protection contre la perte définitive des secrets
    }
  }
  storage_use_azuread = true # comptes de stockage sans clé partagée
}
