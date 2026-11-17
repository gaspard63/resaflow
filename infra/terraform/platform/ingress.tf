# ---------------------------------------------------------------- Traefik (contrôleur d'entrée)
resource "helm_release" "traefik" {
  name       = "traefik"
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  version    = var.chart_versions.traefik
  namespace  = kubernetes_namespace_v1.platform["traefik"].metadata[0].name

  values = [yamlencode({
    deployment          = { replicas = 2 }
    podDisruptionBudget = { enabled = true, minAvailable = 1 }
    ingressClass        = { enabled = true, isDefaultClass = true }
    providers = {
      kubernetesCRD     = { enabled = true, allowCrossNamespace = false }
      kubernetesIngress = { enabled = true } # utilisé par les solveurs HTTP-01 de cert-manager
    }
    ports = {
      web = {
        # HTTP -> HTTPS partout, sauf pour les défis ACME de Let's Encrypt
        allowACMEByPass = true
        http            = { redirections = { entryPoint = { to = "websecure", scheme = "https", permanent = true } } }
      }
    }
    service = {
      spec = { externalTrafficPolicy = "Local" } # conserve l'IP client (limitation de débit par IP)
    }
    log       = { level = "INFO", format = "json" }
    accessLog = { enabled = true, format = "json" } # journal d'accès centralisé dans Loki (A.8.15)
    metrics = {
      prometheus = {
        service        = { enabled = true }
        serviceMonitor = { enabled = true, additionalLabels = { release = "kube-prometheus-stack" } }
      }
    }
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "500m", memory = "256Mi" }
    }
  })]

  depends_on = [helm_release.kube_prometheus_stack] # CRD ServiceMonitor
}

# ---------------------------------------------------------------- cert-manager (certificats TLS Let's Encrypt)
resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = var.chart_versions.cert_manager
  namespace  = kubernetes_namespace_v1.platform["cert-manager"].metadata[0].name

  values = [yamlencode({
    crds       = { enabled = true }
    prometheus = { servicemonitor = { enabled = true, labels = { release = "kube-prometheus-stack" } } }
    resources  = { requests = { cpu = "20m", memory = "64Mi" } }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}

# ClusterIssuers Let's Encrypt (chart local : les CRD cert-manager n'existent pas au moment du plan)
resource "helm_release" "platform_extras" {
  name      = "platform-extras"
  chart     = "${path.module}/charts/platform-extras"
  namespace = kubernetes_namespace_v1.platform["cert-manager"].metadata[0].name

  values = [yamlencode({
    acmeEmail    = var.acme_email
    ingressClass = "traefik"
  })]

  depends_on = [helm_release.cert_manager, helm_release.traefik]
}

data "kubernetes_service_v1" "traefik" {
  metadata {
    name      = "traefik"
    namespace = kubernetes_namespace_v1.platform["traefik"].metadata[0].name
  }
  depends_on = [helm_release.traefik]
}
