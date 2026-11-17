# Coffre-fort des secrets (A.5.17 / A.8.12) : autorisation par Azure RBAC, purge protégée,
# journal d'audit des accès (monitoring.tf). Les secrets sont générés ici (random_password) et
# lus par les pods via le Secrets Store CSI Driver — ils n'apparaissent jamais dans Git ni dans la CI.
#
# Note : l'état Terraform contient ces valeurs ; il est stocké dans un compte de stockage chiffré,
# accessible uniquement par Entra ID (voir bootstrap/).

resource "azurerm_key_vault" "main" {
  name                          = "kv-${local.name}"
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 7
  public_network_access_enabled = true # le runner GitHub et Terraform doivent l'atteindre
  tags                          = var.tags

  network_acls {
    bypass         = "AzureServices"
    default_action = "Allow" # passer à "Deny" + points de terminaison privés en production réelle
  }
}

# Administrateurs + identité Terraform : écriture des secrets
resource "azurerm_role_assignment" "kv_officer" {
  for_each             = local.platform_admins
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

# ---------------------------------------------------------------- Génération des secrets par environnement
resource "random_password" "jwt" {
  for_each = toset(var.environments)
  length   = 64
  special  = false
}

resource "random_password" "postgres_incluster" {
  for_each = toset(var.environments)
  length   = 32
  special  = false
}

resource "random_password" "rabbitmq" {
  for_each = toset(var.environments)
  length   = 32
  special  = false
}

resource "random_password" "admin" {
  for_each = toset(var.environments)
  length   = 20
  special  = true
}

locals {
  pg_fqdn = azurerm_postgresql_flexible_server.main.fqdn
  # Noms des secrets calculés à partir de données NON sensibles : utilisables dans for_each
  # sans recourir à nonsensitive() (les valeurs, elles, restent marquées sensibles).
  secret_kinds     = ["jwt-secret", "rabbitmq-password", "admin-password", "celery-broker-url", "postgres-password", "database-url"]
  env_secret_names = toset(flatten([for env in var.environments : [for k in local.secret_kinds : "${env}-${k}"]]))
  env_secrets = merge([
    for env in var.environments : {
      "${env}-jwt-secret"        = random_password.jwt[env].result
      "${env}-rabbitmq-password" = random_password.rabbitmq[env].result
      "${env}-admin-password"    = random_password.admin[env].result
      "${env}-celery-broker-url" = "amqp://resaflow:${random_password.rabbitmq[env].result}@resaflow-rabbitmq:5672//"
      # prod -> serveur managé (TLS obligatoire) ; dev/staging -> PostgreSQL in-cluster
      "${env}-postgres-password" = env == "prod" ? random_password.postgres_admin.result : random_password.postgres_incluster[env].result
      "${env}-database-url" = (env == "prod"
        ? "postgresql+psycopg://resaflowadmin:${random_password.postgres_admin.result}@${local.pg_fqdn}:5432/resaflow?sslmode=require"
      : "postgresql+psycopg://resaflow:${random_password.postgres_incluster[env].result}@resaflow-postgresql:5432/resaflow")
    }
  ]...)
}

resource "azurerm_key_vault_secret" "env" {
  for_each     = local.env_secret_names
  name         = each.key
  value        = local.env_secrets[each.key]
  key_vault_id = azurerm_key_vault.main.id
  content_type = "text/plain"
  tags         = { environment = split("-", each.key)[0] }

  depends_on = [azurerm_role_assignment.kv_officer]
}
