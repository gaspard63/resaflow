terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm    = { source = "hashicorp/azurerm", version = "~> 4.81" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }
    random     = { source = "hashicorp/random", version = "~> 3.7" }
  }

  # terraform init -backend-config=../azure/backend.hcl -backend-config="key=platform.tfstate"
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
}

data "azurerm_kubernetes_cluster" "main" {
  name                = var.aks_name
  resource_group_name = var.resource_group
}

locals {
  kube_host = data.azurerm_kubernetes_cluster.main.kube_config[0].host
  kube_ca   = base64decode(data.azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate)
  # Comptes locaux désactivés : jeton Entra ID obtenu par kubelogin (session az login ou OIDC en CI)
  kube_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    args        = ["get-token", "--login", "azurecli", "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"]
  }
}

provider "kubernetes" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca
  exec {
    api_version = local.kube_exec.api_version
    command     = local.kube_exec.command
    args        = local.kube_exec.args
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.kube_host
    cluster_ca_certificate = local.kube_ca
    exec                   = local.kube_exec
  }
}
