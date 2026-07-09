variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
}

variable "node_pools" {
  description = "Map of node pool configurations"
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
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "environment" {
  description = "Environment label"
  type        = string
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
