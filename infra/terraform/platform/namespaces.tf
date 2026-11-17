# Séparation des environnements de développement, de test et de production (A.8.31) :
# un namespace par environnement, avec Pod Security Standards "restricted", quotas et limites par défaut.

resource "kubernetes_namespace_v1" "app" {
  for_each = toset(var.environments)
  metadata {
    name = "resaflow-${each.key}"
    labels = {
      "resaflow.io/environment"                    = each.key
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/warn"            = "restricted"
    }
  }
}

resource "kubernetes_resource_quota_v1" "app" {
  for_each = toset(var.environments)
  metadata {
    name      = "resaflow-quota"
    namespace = kubernetes_namespace_v1.app[each.key].metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"           = var.quotas[each.key].requests_cpu
      "requests.memory"        = var.quotas[each.key].requests_memory
      "limits.cpu"             = var.quotas[each.key].limits_cpu
      "limits.memory"          = var.quotas[each.key].limits_memory
      "pods"                   = var.quotas[each.key].pods
      "persistentvolumeclaims" = var.quotas[each.key].pvcs
      "requests.storage"       = "50Gi"
      "services.loadbalancers" = 0 # seul Traefik expose des services publics
      "services.nodeports"     = 0
    }
  }
}

resource "kubernetes_limit_range_v1" "app" {
  for_each = toset(var.environments)
  metadata {
    name      = "resaflow-defaults"
    namespace = kubernetes_namespace_v1.app[each.key].metadata[0].name
  }
  spec {
    limit {
      type            = "Container"
      default         = { cpu = "300m", memory = "256Mi" }
      default_request = { cpu = "50m", memory = "64Mi" }
      max             = { cpu = "2", memory = "2Gi" }
    }
  }
}

resource "kubernetes_namespace_v1" "platform" {
  for_each = {
    traefik      = "baseline"
    cert-manager = "restricted"
    monitoring   = "privileged" # node-exporter lit les métriques de l'hôte
  }
  metadata {
    name = each.key
    labels = {
      "pod-security.kubernetes.io/enforce" = each.value
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}
