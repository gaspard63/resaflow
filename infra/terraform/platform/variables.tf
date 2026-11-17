variable "resource_group" {
  description = "Sortie resource_group de la stack azure"
  type        = string
}

variable "aks_name" {
  description = "Sortie aks_name de la stack azure"
  type        = string
}

variable "deploy_identity_object_id" {
  description = "Sortie github_deploy_principal_id de la stack azure (identité de déploiement de la CI)"
  type        = string
}

variable "environments" {
  type    = list(string)
  default = ["dev", "staging", "prod"]
}

variable "acme_email" {
  description = "E-mail de contact Let's Encrypt (expiration des certificats)"
  type        = string
}

variable "alertmanager_webhook_url" {
  description = "Webhook (Teams, Slack, Discord…) recevant les alertes ; vide = alertes visibles dans Alertmanager/Grafana uniquement"
  type        = string
  default     = ""
  sensitive   = true
}

# Quotas par environnement (garde-fou FinOps et isolation des environnements)
variable "quotas" {
  type = map(object({
    requests_cpu    = string
    requests_memory = string
    limits_cpu      = string
    limits_memory   = string
    pods            = number
    pvcs            = number
  }))
  default = {
    dev     = { requests_cpu = "1", requests_memory = "2Gi", limits_cpu = "4", limits_memory = "5Gi", pods = 20, pvcs = 4 }
    staging = { requests_cpu = "1500m", requests_memory = "3Gi", limits_cpu = "8", limits_memory = "8Gi", pods = 30, pvcs = 4 }
    prod    = { requests_cpu = "3", requests_memory = "5Gi", limits_cpu = "12", limits_memory = "14Gi", pods = 50, pvcs = 4 }
  }
}

variable "chart_versions" {
  description = "Versions épinglées des charts de la plateforme (mises à jour par revue de code)"
  type        = map(string)
  default = {
    traefik               = "41.7.1"
    cert_manager          = "v1.21.2"
    kube_prometheus_stack = "92.3.1"
    loki                  = "6.55.0"
    alloy                 = "1.13.1"
    tempo                 = "1.24.4"
  }
}
