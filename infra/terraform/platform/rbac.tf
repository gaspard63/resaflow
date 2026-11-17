# RBAC Kubernetes complémentaire à Azure RBAC (les deux sont évalués par AKS) :
# l'identité de déploiement peut uniquement INTERROGER Prometheus (analyse canary), rien d'autre
# dans le namespace monitoring — ni lecture des secrets, ni port-forward, ni exec (moindre privilège).
resource "kubernetes_role_v1" "prometheus_query" {
  metadata {
    name      = "prometheus-query"
    namespace = kubernetes_namespace_v1.platform["monitoring"].metadata[0].name
  }
  rule {
    api_groups     = [""]
    resources      = ["services/proxy"]
    resource_names = ["kube-prometheus-stack-prometheus:9090", "kube-prometheus-stack-prometheus"]
    verbs          = ["get"]
  }
}

resource "kubernetes_role_binding_v1" "prometheus_query_ci" {
  metadata {
    name      = "prometheus-query-ci"
    namespace = kubernetes_namespace_v1.platform["monitoring"].metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.prometheus_query.metadata[0].name
  }
  subject {
    kind      = "User"
    api_group = "rbac.authorization.k8s.io"
    name      = var.deploy_identity_object_id
  }
}
