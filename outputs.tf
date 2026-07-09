# ---------------------------------------------------------------------------
# SecondWave GCP Container Platform — Outputs
# ---------------------------------------------------------------------------

output "cluster_endpoint" {
  description = "Private IP address of the GKE cluster control plane"
  value       = module.gke_cluster.endpoint
  sensitive   = true
  # SECURITY SAFEGUARD: Marked sensitive to prevent leakage in CI logs.
  # The endpoint is a private IP reachable only from authorised networks.
}

output "cluster_ca_certificate" {
  description = "Base64-encoded CA certificate for the cluster"
  value       = module.gke_cluster.ca_certificate
  sensitive   = true
}

output "workload_identity_pool" {
  description = "Workload Identity pool name (project.svc.id.goog)"
  value       = module.gke_cluster.workload_identity_pool
}

output "argo_admin_password_secret" {
  description = "Secret Manager resource name for ArgoCD admin password"
  value       = var.gitops_tool == "argo" ? module.gitops_bootstrap[0].admin_password_secret : null
}

output "external_dns_managed_zone" {
  description = "Name of the Google Cloud DNS managed zone for external-dns"
  value       = var.external_dns_enabled ? google_dns_managed_zone.secondwave[0].name : null
}

output "cluster_name" {
  description = "Name of the provisioned GKE cluster"
  value       = module.gke_cluster.name
}

output "project_id" {
  description = "GCP project ID used for deployment"
  value       = var.project_id
}

output "region" {
  description = "GCP region where the cluster is deployed"
  value       = var.region
}

output "artifact_registry_repo" {
  description = "Artifact Registry Docker repository name"
  value       = google_artifact_registry_repository.secondwave.name
}

output "cloud_armor_policy" {
  description = "Cloud Armor security policy name"
  value       = var.cloud_armor_enabled ? google_compute_security_policy.cloud_armor[0].name : null
}

output "gitops_bootstrap_status" {
  description = "Status of GitOps bootstrap completion"
  value       = module.gitops_bootstrap[0].bootstrap_status
}
