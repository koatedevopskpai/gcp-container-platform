# ---------------------------------------------------------------------------
# SecondWave GCP Container Platform — Variables
# ---------------------------------------------------------------------------

variable "project_id" {
  description = "GCP project ID for the container platform (e.g. secondwave-platform-prod)"
  type        = string

  # SECURITY SAFEGUARD: Project ID must not be hardcoded — one repo deploys
  # to multiple environments via different tfvars files.
}

variable "region" {
  description = "GCP region for all resources (e.g. europe-west2 for London)"
  type        = string
  default     = "europe-west2"
}

variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
  default     = "secondwave-gke"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the cluster (e.g. 1.29, 1.30). Use 'latest' for rapid channel."
  type        = string
  default     = "1.30"
}

variable "environment" {
  description = "Environment label: dev, staging, prod"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

# ARCHITECTURE DECISION: Node Pools as Map
# Using a map of objects rather than separate variables for each pool allows
# consumers to define arbitrary node pools (GPU, high-mem, spot) without
# modifying the module interface. This follows the "flat config" pattern
# recommended by HashiCorp for reusable infrastructure.
variable "node_pools" {
  description = <<-EOT
    Map of node pool configurations. Each key is the pool name suffix.
    Example:
    {
      "general" = {
        machine_type  = "e2-standard-4"
        min_count     = 2
        max_count     = 10
        disk_size_gb  = 100
        disk_type     = "pd-ssd"
        spot          = true
        auto_repair   = true
        auto_upgrade  = true
        labels        = { workload = "general" }
        taints        = []
      }
    }
  EOT
  type = map(object({
    machine_type  = string
    min_count     = number
    max_count     = number
    disk_size_gb  = optional(number, 100)
    disk_type     = optional(string, "pd-ssd")
    spot          = optional(bool, false)
    local_ssd_count = optional(number, 0)
    auto_repair   = optional(bool, true)
    auto_upgrade  = optional(bool, true)
    labels        = optional(map(string), {})
    taints        = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
  default = {}
}

variable "vpc_network" {
  description = "Name of the VPC network"
  type        = string
  default     = "default"
}

variable "vpc_subnet" {
  description = "Name of the VPC subnet"
  type        = string
  default     = "default"
}

variable "master_ipv4_cidr_block" {
  description = "CIDR block for the GKE control plane (must be /28)"
  type        = string
  default     = "10.0.0.0/28"
}

variable "pods_ipv4_cidr" {
  description = "Secondary CIDR for GKE pods (VPC-native)"
  type        = string
  default     = "10.1.0.0/16"
}

variable "services_ipv4_cidr" {
  description = "Secondary CIDR for GKE services"
  type        = string
  default     = "10.2.0.0/20"
}

variable "master_authorized_networks" {
  description = "List of CIDR blocks allowed to access the cluster control plane"
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []

  # SECURITY SAFEGUARD: Empty by default — only authorized networks are peering
  # ranges (Cloud Build, ArgoCD runners) never 0.0.0.0/0.
}

variable "cmek_key_name" {
  description = "Full resource name of the CMEK key for GKE encryption"
  type        = string
  default     = null
  # ARCHITECTURE DECISION: CMEK key is injected from outside Terraform
  # because key rotation is managed by the Security team via a separate
  # KMS pipeline. Terraform only references the key.
}

variable "artifact_registry_location" {
  description = "Multi-region or regional location for Artifact Registry"
  type        = string
  default     = "europe"
}

variable "gitops_tool" {
  description = "GitOps tool to bootstrap: 'argo' or 'flux'"
  type        = string
  default     = "argo"

  validation {
    condition     = contains(["argo", "flux"], var.gitops_tool)
    error_message = "GitOps tool must be 'argo' or 'flux'."
  }
}

variable "gitops_repo_url" {
  description = "SSH or HTTPS URL of the GitOps config repository"
  type        = string
  default     = ""
}

variable "gitops_repo_ssh_private_key" {
  description = "SSH private key (base64) for GitOps repo auth — managed via Secret Manager"
  type        = string
  sensitive   = true
  default     = ""
}

variable "domain_name" {
  description = "DNS domain for external-dns and cert-manager (e.g. secondwave.io)"
  type        = string
  default     = ""
}

variable "external_dns_enabled" {
  description = "Enable external-dns with Google Cloud DNS"
  type        = bool
  default     = false
}

variable "cert_manager_email" {
  description = "Email address for Let's Encrypt certificate registration"
  type        = string
  default     = ""
}

variable "cloud_armor_enabled" {
  description = "Enable Cloud Armor security policy for ingress"
  type        = bool
  default     = true
}

variable "binary_authorization_enabled" {
  description = "Enable Binary Authorization with attestation required"
  type        = bool
  default     = true
}

variable "release_channel" {
  description = "GKE release channel: UNSPECIFIED, RAPID, REGULAR, STABLE"
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["UNSPECIFIED", "RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "Release channel must be one of: UNSPECIFIED, RAPID, REGULAR, STABLE."
  }
}

variable "enable_vertical_pod_autoscaling" {
  description = "Enable Vertical Pod Autoscaling"
  type        = bool
  default     = true
}

variable "enable_node_auto_provisioning" {
  description = "Enable Node Auto-Provisioning"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Resource tags for cost allocation and compliance"
  type        = map(string)
  default = {
    managed_by  = "terraform"
    repository  = "gcp-container-platform"
  }
}
