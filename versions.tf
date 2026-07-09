terraform {
  required_version = ">= 1.6, < 2.0"

  # ARCHITECTURE DECISION: GCS Backend for State
  # We use GCS for Terraform state storage instead of local or Terraform Cloud
  # because state locking via GCS object versioning prevents concurrent corruption,
  # and having state in the same GCP project as the infrastructure reduces
  # cross-cloud blast radius. The KMS key (see scripts/bootstrap-backend.sh)
  # encrypts state at rest, mandatory for SecondWave's SOC2 compliance.
  #
  # Uncomment and configure after running scripts/bootstrap-backend.sh:
  # backend "gcs" {
  #   bucket         = "secondwave-tfstate-<ENV>"
  #   prefix         = "gke-container-platform"
  #   encryption_key = "projects/<PROJECT>/locations/global/keyRings/tfstate/cryptoKeys/tfstate-key"
  # }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.30"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# ARCHITECTURE DECISION: Provider Configuration
# The google-beta provider is required for features like GKE Gateway controller
# and CMEK on control plane that are still in beta. We pin to minor versions
# to avoid breaking changes while receiving patch fixes.
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
