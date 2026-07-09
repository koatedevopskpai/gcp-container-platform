variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
}

variable "environment" {
  description = "Environment label"
  type        = string
}

variable "workload_service_accounts" {
  description = "List of workload SA mappings (ksa_namespace, ksa_name, gsa_name, gsa_roles)"
  type = list(object({
    ksa_name      = string
    ksa_namespace = string
    gsa_name      = string
    gsa_roles     = list(string)
  }))
}
