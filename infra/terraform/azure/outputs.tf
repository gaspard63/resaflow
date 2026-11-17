output "resource_group" {
  value = azurerm_resource_group.main.name
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "aks_oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "acr_name" {
  value = azurerm_container_registry.main.name
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}

output "storage_account_url" {
  value = azurerm_storage_account.main.primary_blob_endpoint
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.main.fqdn
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "subscription_id" {
  value = data.azurerm_client_config.current.subscription_id
}

output "github_deploy_principal_id" {
  description = "À passer à la stack platform (deploy_identity_object_id)"
  value       = azurerm_user_assigned_identity.github_deploy.principal_id
}

output "app_identity_client_ids" {
  description = "À passer au chart Helm (azure.workloadIdentityClientId) pour chaque environnement"
  value       = { for env, id in azurerm_user_assigned_identity.app : env => id.client_id }
}

# Variables à créer dans GitHub (Settings > Secrets and variables > Actions > Variables).
# Ce ne sont PAS des secrets : la fédération OIDC rend tout mot de passe inutile.
output "github_actions_variables" {
  value = {
    AZURE_TENANT_ID                = data.azurerm_client_config.current.tenant_id
    AZURE_SUBSCRIPTION_ID          = data.azurerm_client_config.current.subscription_id
    AZURE_CLIENT_ID_DEPLOY         = azurerm_user_assigned_identity.github_deploy.client_id
    AZURE_CLIENT_ID_TERRAFORM      = azurerm_user_assigned_identity.terraform.client_id
    AZURE_RESOURCE_GROUP           = azurerm_resource_group.main.name
    AKS_NAME                       = azurerm_kubernetes_cluster.main.name
    ACR_NAME                       = azurerm_container_registry.main.name
    ACR_LOGIN_SERVER               = azurerm_container_registry.main.login_server
    KEY_VAULT_NAME                 = azurerm_key_vault.main.name
    POSTGRES_SERVER_NAME           = azurerm_postgresql_flexible_server.main.name
    STORAGE_ACCOUNT_URL            = azurerm_storage_account.main.primary_blob_endpoint
    APP_IDENTITY_CLIENT_ID_DEV     = azurerm_user_assigned_identity.app["dev"].client_id
    APP_IDENTITY_CLIENT_ID_STAGING = azurerm_user_assigned_identity.app["staging"].client_id
    APP_IDENTITY_CLIENT_ID_PROD    = azurerm_user_assigned_identity.app["prod"].client_id
  }
}
