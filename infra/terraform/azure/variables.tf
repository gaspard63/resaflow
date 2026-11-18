variable "project" {
  description = "Préfixe des ressources"
  type        = string
  default     = "resaflow"
}

variable "location" {
  description = "Région Azure (France Centre : données hébergées en France)"
  type        = string
  default     = "francecentral"
}

variable "suffix" {
  description = "Suffixe unique pour les noms globaux (ACR, Key Vault, stockage) — 3 à 6 caractères alphanumériques"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]{3,6}$", var.suffix))
    error_message = "3 à 6 caractères minuscules ou chiffres."
  }
}

variable "environments" {
  description = "Environnements hébergés dans le cluster, un namespace chacun (A.8.31)"
  type        = list(string)
  default     = ["dev", "staging", "prod"]
}

variable "github_repository" {
  description = "Dépôt GitHub autorisé à déployer par OIDC (format propriétaire/depot)"
  type        = string
}

variable "admin_object_ids" {
  description = "Object IDs Entra ID des administrateurs humains (votre utilisateur) : az ad signed-in-user show --query id -o tsv"
  type        = list(string)
}

variable "tfstate_storage_account_id" {
  description = "ID du compte de stockage de l'état Terraform (sortie du bootstrap)"
  type        = string
}

variable "aks_admin_group_object_ids" {
  description = "Groupes Entra ID administrateurs du cluster"
  type        = list(string)
  default     = []
}

variable "kubernetes_version" {
  description = "Version mineure de Kubernetes (null = version recommandée par AKS)"
  type        = string
  default     = null
}

variable "system_node_vm_size" {
  description = "Taille des nœuds du pool système (exécute aussi les charges applicatives)"
  type        = string
  default     = "Standard_D2as_v7"
}

variable "system_node_min" {
  type    = number
  default = 1
}

variable "system_node_max" {
  type    = number
  default = 3
}

variable "spot_node_vm_size" {
  description = "Taille des nœuds Spot (workers Celery)"
  type        = string
  default     = "Standard_D2as_v7"
}

variable "spot_node_max" {
  type    = number
  default = 1
}

variable "postgres_sku" {
  description = "SKU du serveur PostgreSQL flexible (Burstable B1ms : dimensionnement FinOps)"
  type        = string
  default     = "B_Standard_B1ms"
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "budget_amount" {
  description = "Budget mensuel en devise de facturation (alertes à 50/80/100 % et prévisionnel)"
  type        = number
  default     = 100
}

variable "budget_contact_emails" {
  type    = list(string)
  default = []
}

variable "budget_start_date" {
  description = "1er jour du mois de démarrage du budget (format AAAA-MM-01T00:00:00Z)"
  type        = string
  default     = "2026-11-01T00:00:00Z"
}

variable "enable_private_endpoints" {
  description = "Points de terminaison privés pour Blob et Key Vault (≈ 7 €/mois chacun) — désactivé par défaut (arbitrage FinOps)"
  type        = bool
  default     = false
}

variable "tags" {
  type = map(string)
  default = {
    project     = "resaflow"
    owner       = "gaspard"
    cost_center = "ecole-hexagone-bc3"
    managed_by  = "terraform"
  }
}
