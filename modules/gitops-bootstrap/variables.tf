variable "gitops_tool" {
  description = "GitOps tool: 'argo' or 'flux'"
  type        = string
}

variable "repo_url" {
  description = "Git repository URL for GitOps config"
  type        = string
}

variable "repo_ssh_key" {
  description = "Base64-encoded SSH private key for repo auth"
  type        = string
  sensitive   = true
  default     = ""
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
}

variable "environment" {
  description = "Environment label"
  type        = string
}

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}
