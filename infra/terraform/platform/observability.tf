# Supervision (A.8.16) : métriques (Prometheus), alertes (Alertmanager), tableaux de bord (Grafana),
# journaux (Loki + Grafana Alloy) et traces distribuées (Tempo), le tout dans le namespace monitoring.
# Grafana n'est PAS exposé publiquement : accès par kubectl port-forward (moindre exposition).

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.platform["monitoring"].metadata[0].name
  }
  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana_admin.result
  }
}

locals {
  alert_receiver = var.alertmanager_webhook_url == "" ? "null" : "webhook"
  alertmanager_receivers = concat(
    [{ name = "null" }],
    var.alertmanager_webhook_url == "" ? [] : [{
      name            = "webhook"
      webhook_configs = [{ url = var.alertmanager_webhook_url, send_resolved = true }]
    }]
  )
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.chart_versions.kube_prometheus_stack
  namespace  = kubernetes_namespace_v1.platform["monitoring"].metadata[0].name
  timeout    = 900

  values = [yamlencode({
    # AKS gère le plan de contrôle : ces cibles ne sont pas joignables
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeEtcd              = { enabled = false }
    kubeProxy             = { enabled = false }

    prometheus = {
      prometheusSpec = {
        retention                               = "15d"
        retentionSize                           = "8GB"
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
        resources = {
          requests = { cpu = "100m", memory = "512Mi" }
          limits   = { memory = "1536Mi" }
        }
        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = "managed-csi"
              accessModes      = ["ReadWriteOnce"]
              resources        = { requests = { storage = "10Gi" } }
            }
          }
        }
      }
    }

    alertmanager = {
      config = {
        route = {
          receiver        = local.alert_receiver
          group_by        = ["alertname", "namespace"]
          group_wait      = "30s"
          group_interval  = "5m"
          repeat_interval = "4h"
          routes = [
            { receiver = "null", matchers = ["alertname = Watchdog"] },
            { receiver = "null", matchers = ["alertname = InfoInhibitor"] },
            { receiver = local.alert_receiver, matchers = ["severity =~ \"critical|warning\""] },
          ]
        }
        receivers     = local.alertmanager_receivers
        inhibit_rules = [{ source_matchers = ["severity = critical"], target_matchers = ["severity = warning"], equal = ["alertname", "namespace"] }]
      }
    }

    grafana = {
      admin = { existingSecret = kubernetes_secret_v1.grafana_admin.metadata[0].name }
      "grafana.ini" = {
        auth             = { disable_login_form = false }
        "auth.anonymous" = { enabled = false }
        security         = { cookie_secure = true, disable_gravatar = true }
        analytics        = { reporting_enabled = false, check_for_updates = false }
      }
      sidecar = {
        dashboards = {
          enabled          = true
          label            = "grafana_dashboard"
          searchNamespace  = "ALL"
          folderAnnotation = "grafana_folder"
          provider         = { foldersFromFilesStructure = true }
        }
      }
      additionalDataSources = [
        {
          name = "Loki", uid = "loki", type = "loki", access = "proxy"
          url  = "http://loki.monitoring.svc.cluster.local:3100"
          jsonData = {
            derivedFields = [{ name = "trace_id", matcherRegex = "\"trace_id\":\"(\\w+)\"", datasourceUid = "tempo", url = "$${__value.raw}" }]
          }
        },
        {
          name     = "Tempo", uid = "tempo", type = "tempo", access = "proxy"
          url      = "http://tempo.monitoring.svc.cluster.local:3200"
          jsonData = { tracesToLogsV2 = { datasourceUid = "loki", filterByTraceID = true } }
        },
      ]
      persistence = { enabled = true, size = "2Gi", storageClassName = "managed-csi" }
    }
  })]
}

# ---------------------------------------------------------------- Loki (journaux), mode binaire unique
resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.chart_versions.loki
  namespace  = kubernetes_namespace_v1.platform["monitoring"].metadata[0].name
  timeout    = 600

  values = [yamlencode({
    deploymentMode = "SingleBinary"
    loki = {
      auth_enabled = false
      commonConfig = { replication_factor = 1 }
      storage      = { type = "filesystem" }
      schemaConfig = {
        configs = [{
          from  = "2026-01-01", store = "tsdb", object_store = "filesystem", schema = "v13"
          index = { prefix = "loki_index_", period = "24h" }
        }]
      }
      limits_config = { retention_period = "336h" } # 14 jours
      compactor     = { retention_enabled = true, delete_request_store = "filesystem" }
    }
    singleBinary = {
      replicas    = 1
      persistence = { enabled = true, size = "10Gi", storageClass = "managed-csi" }
      resources   = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = "1Gi" } }
    }
    read         = { replicas = 0 }
    write        = { replicas = 0 }
    backend      = { replicas = 0 }
    gateway      = { enabled = false }
    chunksCache  = { enabled = false } # FinOps : caches memcached inutiles à ce volume
    resultsCache = { enabled = false }
    lokiCanary   = { enabled = false }
    test         = { enabled = false }
    monitoring   = { serviceMonitor = { enabled = true, labels = { release = "kube-prometheus-stack" } } }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}

# ---------------------------------------------------------------- Grafana Alloy (collecte des journaux des pods)
resource "helm_release" "alloy" {
  name       = "alloy"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = var.chart_versions.alloy
  namespace  = kubernetes_namespace_v1.platform["monitoring"].metadata[0].name

  values = [yamlencode({
    controller = { type = "daemonset" }
    alloy = {
      configMap = { content = file("${path.module}/alloy/config.alloy") }
      resources = { requests = { cpu = "20m", memory = "64Mi" }, limits = { memory = "256Mi" } }
    }
  })]

  depends_on = [helm_release.loki]
}

# ---------------------------------------------------------------- Tempo (traces distribuées OTLP)
resource "helm_release" "tempo" {
  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  version    = var.chart_versions.tempo
  namespace  = kubernetes_namespace_v1.platform["monitoring"].metadata[0].name

  values = [yamlencode({
    tempo = {
      retention = "72h"
      receivers = { otlp = { protocols = { http = { endpoint = "0.0.0.0:4318" }, grpc = { endpoint = "0.0.0.0:4317" } } } }
      resources = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = "512Mi" } }
    }
    persistence    = { enabled = true, size = "5Gi", storageClassName = "managed-csi" }
    serviceMonitor = { enabled = true, additionalLabels = { release = "kube-prometheus-stack" } }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}
