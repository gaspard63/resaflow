# ---------------------------------------------------------------- Registre d'images
resource "azurerm_container_registry" "main" {
  name                = "acr${local.flat}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic" # FinOps : 10 Go inclus, suffisant pour le projet
  admin_enabled       = false   # aucun identifiant partagé : push par OIDC (CI), pull par l'identité kubelet
  tags                = var.tags
}

# ---------------------------------------------------------------- Cluster AKS
resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${local.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = local.name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = "Free" # FinOps : pas de SLA payant pour un projet pédagogique

  # Sécurité : authentification Entra ID uniquement, autorisation Azure RBAC (A.5.15, A.8.2, A.8.5)
  local_account_disabled            = true
  role_based_access_control_enabled = true
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = true
    tenant_id              = data.azurerm_client_config.current.tenant_id
    admin_group_object_ids = var.aks_admin_group_object_ids
  }

  # Workload Identity : les pods obtiennent des jetons Entra ID sans aucun secret stocké
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Secrets Store CSI Driver + fournisseur Azure Key Vault (A.5.17), rotation toutes les 2 min
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  # Mises à jour automatiques des correctifs Kubernetes et des images de nœuds (A.8.8)
  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"
  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Sunday"
    start_time  = "02:00"
    utc_offset  = "+01:00"
  }

  image_cleaner_enabled        = true # supprime les images vulnérables inutilisées des nœuds
  image_cleaner_interval_hours = 48

  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_node_vm_size
    vnet_subnet_id               = azurerm_subnet.aks.id
    auto_scaling_enabled         = true # Cluster Autoscaler : ajoute/retire des nœuds selon les pods en attente
    min_count                    = var.system_node_min
    max_count                    = var.system_node_max
    os_disk_size_gb              = 64
    os_disk_type                 = "Managed"
    max_pods                     = 110
    temporary_name_for_rotation  = "systemtmp"
    only_critical_addons_enabled = false # FinOps : les pods applicatifs partagent ce pool
    upgrade_settings {
      max_surge = "1"
    }
    tags = var.tags
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium" # applique les NetworkPolicies du chart
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.0.0.0/16"
    dns_service_ip      = "10.0.0.10"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }

  # Journaux du plan de contrôle (audit) envoyés vers Log Analytics : voir monitoring.tf
  tags = var.tags

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count, # piloté par l'autoscaler
      kubernetes_version,              # piloté par le canal de mise à jour automatique
    ]
  }
}

# FinOps : pool Spot (jusqu'à -90 %) pour les workers Celery, qui tolèrent l'éviction
# (tâches idempotentes, acks tardifs, repli possible sur le pool système). Peut descendre à 0 nœud.
resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  name                  = "spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.spot_node_vm_size
  vnet_subnet_id        = azurerm_subnet.aks.id
  priority              = "Spot"
  eviction_policy       = "Delete"
  spot_max_price        = -1 # jamais plus cher que le prix à la demande
  auto_scaling_enabled  = true
  min_count             = 0
  max_count             = var.spot_node_max
  os_disk_size_gb       = 64
  node_labels           = { "kubernetes.azure.com/scalesetpriority" = "spot" }
  node_taints           = ["kubernetes.azure.com/scalesetpriority=spot:NoSchedule"]
  tags                  = var.tags

  lifecycle {
    ignore_changes = [node_count]
  }
}

# Le kubelet tire les images de l'ACR avec son identité managée (aucun imagePullSecret)
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# Administrateurs humains + identité Terraform de la CI : administration du cluster (stack plateforme)
resource "azurerm_role_assignment" "aks_cluster_admin" {
  for_each             = local.platform_admins
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}
