# Identités managées et fédération OIDC : AUCUN secret de connexion à Azure n'est stocké,
# ni dans le cluster, ni dans GitHub (A.5.17, A.8.2, A.8.5).

locals {
  oidc_issuer = azurerm_kubernetes_cluster.main.oidc_issuer_url
  # Clés statiques (for_each), valeurs connues seulement après création
  platform_admins = merge(
    { for i, id in var.admin_object_ids : "admin-${i}" => id },
    { terraform-ci = azurerm_user_assigned_identity.terraform.principal_id },
  )
}

# ---------------------------------------------------------------- Application : 1 identité par environnement
resource "azurerm_user_assigned_identity" "app" {
  for_each            = toset(var.environments)
  name                = "id-${local.name}-app-${each.key}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = merge(var.tags, { environment = each.key })
}

# Le ServiceAccount "resaflow" du namespace resaflow-<env> peut emprunter cette identité
resource "azurerm_federated_identity_credential" "app" {
  for_each                  = toset(var.environments)
  name                      = "aks-resaflow-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.app[each.key].id
  issuer                    = local.oidc_issuer
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "system:serviceaccount:resaflow-${each.key}:resaflow"
}

# Moindre privilège : lecture/écriture des SEULS conteneurs de son environnement
resource "azurerm_role_assignment" "app_blob" {
  for_each             = local.containers
  scope                = azurerm_storage_container.containers[each.key].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.app[each.value.env].principal_id
}

# Moindre privilège : lecture des SEULS secrets de son environnement (portée = le secret)
resource "azurerm_role_assignment" "app_kv" {
  for_each             = local.env_secret_names
  scope                = azurerm_key_vault_secret.env[each.key].resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app[split("-", each.key)[0]].principal_id
}

# ---------------------------------------------------------------- CI/CD GitHub Actions (déploiement applicatif)
resource "azurerm_user_assigned_identity" "github_deploy" {
  name                = "id-${local.name}-github-deploy"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

# Fédération : seuls la branche main et les environnements GitHub protégés obtiennent un jeton
resource "azurerm_federated_identity_credential" "github_deploy" {
  for_each = {
    main       = "repo:${var.github_repository}:ref:refs/heads/main"
    dev        = "repo:${var.github_repository}:environment:dev"
    staging    = "repo:${var.github_repository}:environment:staging"
    production = "repo:${var.github_repository}:environment:production"
  }
  name                      = "github-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.github_deploy.id
  issuer                    = "https://token.actions.githubusercontent.com"
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = each.value
}

resource "azurerm_role_assignment" "github_acr_push" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.github_deploy.principal_id
}

# Récupération du kubeconfig (sans droit Kubernetes en soi)
resource "azurerm_role_assignment" "github_aks_user" {
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azurerm_user_assigned_identity.github_deploy.principal_id
}

# Droits Kubernetes limités aux namespaces applicatifs (pas de droits cluster-wide)
resource "azurerm_role_assignment" "github_aks_namespace_admin" {
  for_each             = toset(var.environments)
  scope                = "${azurerm_kubernetes_cluster.main.id}/namespaces/resaflow-${each.key}"
  role_definition_name = "Azure Kubernetes Service RBAC Admin"
  principal_id         = azurerm_user_assigned_identity.github_deploy.principal_id
}

# (L'analyse canary interroge Prometheus via un Role Kubernetes dédié : voir platform/rbac.tf)

# Arrêt/démarrage planifié du cluster (optimisation FinOps)
resource "azurerm_role_definition" "aks_start_stop" {
  name        = "resaflow-aks-start-stop-${var.suffix}"
  scope       = azurerm_kubernetes_cluster.main.id
  description = "Démarrer, arrêter et lire le cluster AKS ResaFlow (FinOps)"
  permissions {
    actions = [
      "Microsoft.ContainerService/managedClusters/read",
      "Microsoft.ContainerService/managedClusters/start/action",
      "Microsoft.ContainerService/managedClusters/stop/action",
    ]
  }
  assignable_scopes = [azurerm_kubernetes_cluster.main.id]
}

resource "azurerm_role_assignment" "github_aks_start_stop" {
  scope              = azurerm_kubernetes_cluster.main.id
  role_definition_id = azurerm_role_definition.aks_start_stop.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.github_deploy.principal_id
}

resource "azurerm_role_definition" "postgres_start_stop" {
  name        = "resaflow-psql-start-stop-${var.suffix}"
  scope       = azurerm_postgresql_flexible_server.main.id
  description = "Démarrer, arrêter et lire le serveur PostgreSQL ResaFlow (FinOps)"
  permissions {
    actions = [
      "Microsoft.DBforPostgreSQL/flexibleServers/read",
      "Microsoft.DBforPostgreSQL/flexibleServers/start/action",
      "Microsoft.DBforPostgreSQL/flexibleServers/stop/action",
    ]
  }
  assignable_scopes = [azurerm_postgresql_flexible_server.main.id]
}

resource "azurerm_role_assignment" "github_postgres_start_stop" {
  scope              = azurerm_postgresql_flexible_server.main.id
  role_definition_id = azurerm_role_definition.postgres_start_stop.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.github_deploy.principal_id
}

# ---------------------------------------------------------------- CI/CD GitHub Actions (Terraform)
resource "azurerm_user_assigned_identity" "terraform" {
  name                = "id-${local.name}-github-terraform"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "terraform" {
  for_each = {
    infra = "repo:${var.github_repository}:environment:infra" # apply (environnement protégé)
    pr    = "repo:${var.github_repository}:pull_request"      # plan sur les pull requests
  }
  name                      = "github-terraform-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.terraform.id
  issuer                    = "https://token.actions.githubusercontent.com"
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = each.value
}

# Portée limitée au groupe de ressources du projet (pas de droits sur l'abonnement)
resource "azurerm_role_assignment" "terraform_contributor" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.terraform.principal_id
}

resource "azurerm_role_assignment" "terraform_rbac_admin" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.terraform.principal_id
}

resource "azurerm_role_assignment" "terraform_state" {
  scope                = var.tfstate_storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.terraform.principal_id
}
