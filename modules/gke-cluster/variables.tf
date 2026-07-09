variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.30"
}

variable "environment" {
  description = "Environment label: dev, staging, prod"
  type        = string
}

variable "vpc_network" {
  description = "VPC network name"
  type        = string
}

variable "vpc_subnet" {
  description = "VPC subnet name"
  type        = string
}

variable "master_ipv4_cidr_block" {
  description = "CIDR block for control plane (must be /28)"
  type        = string
}

variable "pods_ipv4_cidr" {
  description = "Secondary CIDR for pods"
  type        = string
}

variable "services_ipv4_cidr" {
  description = "Secondary CIDR for services"
  type        = string
}

variable "master_authorized_networks" {
  description = "List of CIDRs authorised for control plane access"
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "cmek_key_name" {
  description = "Full resource name of the CMEK key"
  type        = string
  default     = null
}

variable "release_channel" {
  description = "GKE release channel"
  type        = string
  default     = "REGULAR"
}

variable "enable_vertical_pod_autoscaling" {
  description = "Enable VPA"
  type        = bool
  default     = true
}

variable "enable_node_auto_provisioning" {
  description = "Enable NAP"
  type        = bool
  default     = true
}

variable "binary_authorization_enabled" {
  description = "Enable Binary Authorization"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
