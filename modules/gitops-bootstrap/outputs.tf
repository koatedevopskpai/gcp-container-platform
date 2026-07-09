output "admin_password_secret" {
  description = "Secret Manager resource for ArgoCD admin password"
  value       = var.gitops_tool == "argo" ? "projects/${var.project_id}/secrets/${var.cluster_name}-argocd-admin" : null
}

output "bootstrap_status" {
  description = "Status of the GitOps bootstrap"
  value       = "bootstrapped"
}

output "gitops_namespace" {
  description = "Namespace where GitOps tool is installed"
  value       = var.gitops_tool == "argo" ? "argocd" : "flux-system"
}
