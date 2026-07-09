output "endpoint" {
  description = "Private IP of the cluster control plane"
  value       = google_container_cluster.primary.private_cluster_config[0].private_endpoint
}

output "ca_certificate" {
  description = "Base64-encoded CA cert for the cluster"
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
}

output "workload_identity_pool" {
  description = "Workload Identity pool"
  value       = "${var.project_id}.svc.id.goog"
}

output "name" {
  description = "Cluster name"
  value       = google_container_cluster.primary.name
}

output "cluster_resource_name" {
  description = "Full cluster resource name for Binary Authorization"
  value       = "projects/${var.project_id}/locations/${var.region}/clusters/${google_container_cluster.primary.name}"
}

output "kubernetes_endpoint" {
  description = "Public endpoint (if ever exposed) - null for private clusters"
  value       = google_container_cluster.primary.private_cluster_config[0].public_endpoint
}
