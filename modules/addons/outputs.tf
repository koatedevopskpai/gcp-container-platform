output "addons_deployed" {
  description = "List of deployed addon names"
  value = compact([
    var.cert_manager_email != "" ? "cert-manager" : null,
    var.external_dns_enabled ? "external-dns" : null,
    "external-secrets",
    "kyverno",
    "ingress-nginx",
    "opentelemetry-operator",
  ])
}

output "kyverno_namespace" {
  value = "kyverno"
}

output "eso_cluster_secret_store" {
  value = "gcp-secret-manager"
}
