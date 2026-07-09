output "workload_identity_pool" {
  description = "Workload Identity pool"
  value       = "${var.project_id}.svc.id.goog"
}

output "gsa_emails" {
  description = "Map of GSA emails"
  value = {
    for k, v in google_service_account.workload : k => v.email
  }
}

output "workload_identity_bindings" {
  description = "List of created Workload Identity bindings"
  value = [
    for k, v in google_service_account_iam_member.workload_identity_binding : {
      ksa       = k
      member    = v.member
      gsa_email = v.service_account_id
    }
  ]
}
