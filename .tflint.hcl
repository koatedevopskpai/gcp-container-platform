# ============================================================================
# TFLint Configuration — SecondWave GCP Container Platform
# ============================================================================

config {
  format = "compact"

  # ARCHITECTURE DECISION: Call module sources from local filesystem
  # We set module to false because Terraform modules are local (./modules/).
  # For CI, TFLint runs in the root module only.
  module = false

  # SECURITY SAFEGUARD: Force strict variable type checking
  # TFLint catches misconfigured variables at lint time rather than plan time.
  force = false
}

plugin "google" {
  enabled = true
  version = "0.28.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"

  # ARCHITECTURE DECISION: Google-specific lint rules
  # This plugin checks GKE, GCP IAM, and compute resource configurations
  # for common misconfigurations.
}

rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_module_pinned_source" {
  enabled = true
  style = "flexible"
}

rule "terraform_naming_convention" {
  enabled = true
  format = "snake_case"
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_standard_module_structure" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_unused_required_providers" {
  enabled = true
}

rule "terraform_workspace_remote" {
  enabled = true
}
