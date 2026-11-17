output "ingress_public_ip" {
  description = "IP publique de Traefik — le domaine de démo est resaflow-<env>.<ip>.sslip.io"
  value       = try(data.kubernetes_service_v1.traefik.status[0].load_balancer[0].ingress[0].ip, "en attente")
}

output "grafana_admin_password" {
  value     = random_password.grafana_admin.result
  sensitive = true
}

output "namespaces" {
  value = [for ns in kubernetes_namespace_v1.app : ns.metadata[0].name]
}
