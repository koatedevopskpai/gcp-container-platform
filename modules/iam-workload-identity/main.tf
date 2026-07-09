# ============================================================================
# IAM Workload Identity Module — SecondWave Container Platform
# ============================================================================
# ARCHITECTURE DECISION: Workload Identity for Keyless Auth
# For every workload that needs to access GCP APIs (Secret Manager,
# Cloud SQL, GCS, Pub/Sub), we create:
# 1. A GCP service account (GSA) with the minimum IAM roles needed
# 2. A Kubernetes service account (KSA) in the workload's namespace
# 3. An IAM binding allowing the KSA to impersonate the GSA
#
# This replaces the legacy approach of:
# - Storing GCP SA keys in Kubernetes Secrets (rotation nightmare)
# - Giving all nodes cloud-platform scope (privilege escalation risk)
# - Using Workload Identity Federation with external IdPs (overkill here)
#
# SECURITY SAFEGUARD: No GCP SA keys are ever generated. The binding
# is purely IAM-based — the GSA key material does not exist. If the
# binding is removed, the workload loses access immediately with no
# stale keys to revoke.
# ============================================================================

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
  description = "List of workload service account mappings"
  type = list(object({
    ksa_name      = string
    ksa_namespace = string
    gsa_name      = string
    gsa_roles     = list(string)
  }))
}

# ---------------------------------------------------------------------------
# GCP Service Accounts for Workloads
# ---------------------------------------------------------------------------
resource "google_service_account" "workload" {
  for_each = {
    for sa in var.workload_service_accounts : "${sa.ksa_namespace}/${sa.ksa_name}" => sa
  }

  project      = var.project_id
  account_id   = each.value.gsa_name
  display_name = "Workload SA for ${each.value.ksa_namespace}/${each.value.ksa_name}"
  description  = "GCP SA for K8s service account ${each.value.ksa_namespace}/${each.value.ksa_name} via Workload Identity"

  # ARCHITECTURE DECISION: Account ID Constraints
  # GCP service account IDs are limited to 30 characters and must match
  # regex `^[a-z](?:[-a-z0-9]{0,28}[a-z0-9])$`. We enforce this in
  # the naming of gsa_name inputs.
}

# ---------------------------------------------------------------------------
# IAM Roles for each GSA
# ---------------------------------------------------------------------------
resource "google_project_iam_member" "workload_roles" {
  for_each = {
    for pair in flatten([
      for sa in var.workload_service_accounts : [
        for role in sa.gsa_roles : {
          key  = "${sa.gsa_name}:${role}"
          name = sa.gsa_name
          role = role
        }
      ]
    ]) : pair.key => pair
  }

  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.workload[for k, v in var.workload_service_accounts : k if v.gsa_name == each.value.name][0].email}"
}

# ---------------------------------------------------------------------------
# Workload Identity Binding: KSA → GSA
# ---------------------------------------------------------------------------
resource "google_service_account_iam_member" "workload_identity_binding" {
  for_each = {
    for sa in var.workload_service_accounts : "${sa.ksa_namespace}/${sa.ksa_name}" => sa
  }

  service_account_id = google_service_account.workload[each.key].name
  role               = "roles/iam.workloadIdentityUser"

  # SECURITY SAFEGUARD: The member is scoped to a specific KSA in a
  # specific namespace. This prevents a compromised KSA in another
  # namespace from impersonating this GSA.
  member = "serviceAccount:${var.project_id}.svc.id.goog[${each.value.ksa_namespace}/${each.value.ksa_name}]"
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "workload_identity_pool" {
  description = "Workload Identity pool"
  value       = "${var.project_id}.svc.id.goog"
}

output "gsa_emails" {
  description = "Map of workload KSA to GSA email"
  value = {
    for k, v in google_service_account.workload : k => v.email
  }
}

output "gsa_names" {
  description = "Map of workload KSA to GSA name"
  value = {
    for k, v in google_service_account.workload : k => v.name
  }
}
