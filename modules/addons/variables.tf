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

variable "region" {
  description = "GCP region"
  type        = string
}

variable "domain_name" {
  description = "DNS domain"
  type        = string
  default     = ""
}

variable "cert_manager_email" {
  description = "Email for Let's Encrypt"
  type        = string
  default     = ""
}

variable "external_dns_enabled" {
  description = "Enable external-dns"
  type        = bool
  default     = false
}

variable "cloud_armor_enabled" {
  description = "Enable Cloud Armor"
  type        = bool
  default     = true
}
