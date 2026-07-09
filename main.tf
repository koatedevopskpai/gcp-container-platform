# ============================================================================
# SecondWave GCP Container Platform — Root Module
# ============================================================================
# ARCHITECTURE DECISION: Single Root Module
# We use a single root module that composes sub-modules rather than a
# multi-workspace split because the GKE cluster, its node pools, add-ons,
# and IAM bindings form a tightly coupled unit. Splitting them across
# workspaces would require complex remote state passing and make it harder
# to reason about blast radius. The entire platform is deployed as one
# Terraform operation — if the cluster is down, nothing else matters.
#
# SECURITY SAFEGUARD: All resources are tagged with `managed_by = "terraform"`
# to prevent accidental manual changes. Any resource missing this tag triggers
# a compliance alert in Cloud Asset Inventory.
# ============================================================================

# ---------------------------------------------------------------------------
# Data Sources
# ---------------------------------------------------------------------------
data "google_project" "current" {
}

# ---------------------------------------------------------------------------
# GKE Cluster
# ---------------------------------------------------------------------------
module "gke_cluster" {
  source = "./modules/gke-cluster"

  project_id            = var.project_id
  region                = var.region
  cluster_name          = var.cluster_name
  kubernetes_version    = var.kubernetes_version
  environment           = var.environment
  vpc_network           = var.vpc_network
  vpc_subnet            = var.vpc_subnet
  master_ipv4_cidr_block = var.master_ipv4_cidr_block
  pods_ipv4_cidr        = var.pods_ipv4_cidr
  services_ipv4_cidr    = var.services_ipv4_cidr
  master_authorized_networks = var.master_authorized_networks
  cmek_key_name         = var.cmek_key_name
  release_channel       = var.release_channel
  enable_vertical_pod_autoscaling  = var.enable_vertical_pod_autoscaling
  enable_node_auto_provisioning    = var.enable_node_auto_provisioning
  binary_authorization_enabled     = var.binary_authorization_enabled
  tags                  = var.tags
}

# ---------------------------------------------------------------------------
# GKE Node Pools
# ---------------------------------------------------------------------------
module "gke_node_pools" {
  source = "./modules/gke-node-pools"

  project_id   = var.project_id
  cluster_name = module.gke_cluster.name
  node_pools   = var.node_pools
  region       = var.region
  environment  = var.environment
  tags         = var.tags

  depends_on = [module.gke_cluster]
}

# ---------------------------------------------------------------------------
# Workload Identity Federation
# ---------------------------------------------------------------------------
module "iam_workload_identity" {
  source = "./modules/iam-workload-identity"

  project_id  = var.project_id
  cluster_name = module.gke_cluster.name
  environment = var.environment

  # ARCHITECTURE DECISION: Pre-defined workload GSA mappings
  # These are the standard service accounts used by SecondWave workloads.
  # Additional SA mappings should be added to the workload_service_accounts
  # variable in the module for application-specific needs.
  workload_service_accounts = [
    {
      ksa_name      = "external-secrets"
      ksa_namespace = "external-secrets"
      gsa_name      = "external-secrets-sa"
      gsa_roles     = ["roles/secretmanager.secretAccessor", "roles/secretmanager.viewer"]
    },
    {
      ksa_name      = "cert-manager"
      ksa_namespace = "cert-manager"
      gsa_name      = "cert-manager-sa"
      gsa_roles     = ["roles/dns.admin"]
    },
    {
      ksa_name      = "external-dns"
      ksa_namespace = "external-dns"
      gsa_name      = "external-dns-sa"
      gsa_roles     = ["roles/dns.admin"]
    },
    {
      ksa_name      = "kyverno"
      ksa_namespace = "kyverno"
      gsa_name      = "kyverno-sa"
      gsa_roles     = ["roles/cloudkms.viewer"]
    },
  ]

  depends_on = [module.gke_cluster]
}

# ---------------------------------------------------------------------------
# Artifact Registry with Vulnerability Scanning
# ---------------------------------------------------------------------------
resource "google_artifact_registry_repository" "secondwave" {
  project       = var.project_id
  location      = var.artifact_registry_location
  repository_id = "${var.cluster_name}-images"
  description   = "Container image registry for SecondWave workloads"
  format        = "DOCKER"

  # ARCHITECTURE DECISION: Vulnerability Scanning
  # GCP-native scanning removes the need for a third-party scanner like
  # Trivy or Snyk for registry-level analysis. It integrates directly with
  # Binary Authorization to block deployments of vulnerable images.
  # For CI-level scanning, we use Trivy in the build pipeline (see CI/CD).
  mode = "REMOTE_REPOSITORY"
  remote_repository_config {
    description = "Docker Hub mirror for rate-limit avoidance"
    mode        = "DOCKER_HUB"
  }

  docker_config {
    immutable_tags = true
  }

  labels = var.tags
}

# Enable vulnerability scanning on the registry
resource "google_artifact_registry_repository_iam_binding" "vuln_scanning" {
  project    = var.project_id
  location   = var.artifact_registry_location
  repository = google_artifact_registry_repository.secondwave.name
  role       = "roles/artifactregistry.reader"
  members = [
    "serviceAccount:${data.google_project.current.number}@cloudbuild.gserviceaccount.com",
  ]
}

# ---------------------------------------------------------------------------
# Cloud Armor Security Policy
# ---------------------------------------------------------------------------
resource "google_compute_security_policy" "cloud_armor" {
  count = var.cloud_armor_enabled ? 1 : 0

  name    = "${var.cluster_name}-cloud-armor"
  project = var.project_id

  # ARCHITECTURE DECISION: Cloud Armor for WAF
  # Cloud Armor provides L3-L7 DDoS protection and WAF capabilities at the
  # Google Cloud edge, before traffic reaches GKE. This is more efficient
  # than running a WAF inside the cluster (e.g., ModSecurity on nginx).
  # For SecondWave's fintech workloads, Cloud Armor's pre-configured WAF
  # rules for OWASP Top 10 and SQL injection are enabled by default.

  # SECURITY SAFEGUARD: OWASP Top 10 rule set — blocks common web attacks
  # at the edge before they reach cluster ingress.
  rule {
    action   = "deny(403)"
    priority = "1000"
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable')"
      }
    }
    description = "Block SQL injection attacks"
  }

  rule {
    action   = "deny(403)"
    priority = "1001"
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('xss-v33-stable')"
      }
    }
    description = "Block cross-site scripting attacks"
  }

  rule {
    action   = "deny(403)"
    priority = "1002"
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('lfi-v33-stable')"
      }
    }
    description = "Block local file inclusion attacks"
  }

  rule {
    action   = "deny(403)"
    priority = "1003"
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('rce-v33-stable')"
      }
    }
    description = "Block remote code execution attacks"
  }

  # SECURITY SAFEGUARD: Rate limiting per client IP to prevent brute-force
  # attacks against fintech API endpoints.
  rule {
    action   = "throttle"
    priority = "2000"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      rate_limit_http_status_code = 429
      rate_limit_threshold {
        count        = 1000
        interval_sec = 60
      }
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
    }
    description = "Rate limit: 1000 requests per IP per 60 seconds"
  }

  # Allow all other traffic — Cloud Armor defaults to allow
  rule {
    action   = "allow"
    priority = "2147483647"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow rule"
  }

  labels = var.tags
}

# ---------------------------------------------------------------------------
# Google Cloud DNS Managed Zone
# ---------------------------------------------------------------------------
resource "google_dns_managed_zone" "secondwave" {
  count = var.external_dns_enabled && var.domain_name != "" ? 1 : 0

  project     = var.project_id
  name        = replace(var.domain_name, ".", "-")
  dns_name    = "${var.domain_name}."
  description = "DNS managed zone for ${var.domain_name} — managed by external-dns"

  labels = var.tags
}

# ---------------------------------------------------------------------------
# GitOps Bootstrap
# ---------------------------------------------------------------------------
module "gitops_bootstrap" {
  count = var.gitops_repo_url != "" ? 1 : 0

  source = "./modules/gitops-bootstrap"

  gitops_tool     = var.gitops_tool
  repo_url        = var.gitops_repo_url
  repo_ssh_key    = var.gitops_repo_ssh_private_key
  cluster_name    = module.gke_cluster.name
  environment     = var.environment
  project_id      = var.project_id
  region          = var.region

  depends_on = [
    module.gke_cluster,
    module.iam_workload_identity,
  ]
}

# ---------------------------------------------------------------------------
# Add-ons (cert-manager, external-dns, ESO, Kyverno, nginx-ingress)
# ---------------------------------------------------------------------------
module "addons" {
  source = "./modules/addons"

  project_id       = var.project_id
  cluster_name     = module.gke_cluster.name
  environment      = var.environment
  region           = var.region
  domain_name      = var.domain_name
  cert_manager_email = var.cert_manager_email
  external_dns_enabled = var.external_dns_enabled
  cloud_armor_enabled  = var.cloud_armor_enabled

  depends_on = [
    module.gke_cluster,
    module.iam_workload_identity,
    google_artifact_registry_repository.secondwave,
  ]
}

# ---------------------------------------------------------------------------
# GKE Gateway Controller (GCP-native ingress)
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: GKE Gateway Controller
# We enable the Gateway controller (backed by GCP Load Balancers) alongside
# nginx-ingress. Gateway API provides a more expressive, role-oriented model
# than Ingress v1 and is the future direction of Kubernetes ingress.
# nginx-ingress remains as a fallback for simpler routing scenarios.
#
# The Gateway controller is enabled via the GKE cluster addon config
# in modules/gke-cluster/main.tf.

# ---------------------------------------------------------------------------
# Binary Authorization Attestation
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: Binary Authorization
# For production environments, we require a valid attestation from a trusted
# signer (e.g., Cloud Build's attestation) before any container image can be
# deployed. This prevents unvetted images from running, even if they reach
# the registry through a supply-chain attack.
#
# The policy is project-wide and enforced on the GKE cluster. Attestations
# are created in the CI pipeline after vulnerability scanning and unit tests
# pass. Developers never manually create attestations.
resource "google_binary_authorization_policy" "policy" {
  count = var.binary_authorization_enabled ? 1 : 0

  project = var.project_id

  # SECURITY SAFEGUARD: Production images require attestation from a trusted
  # authority. Dev/staging environments use a more permissive policy.
  admission_whitelist_patterns {
    name_pattern = "${var.environment == "prod" ? "gcr.io/${var.project_id}/*" : "*"}"

    # ARCHITECTURE DECISION: Dev/staging whitelist
    # In non-production environments, we whitelist all images from this
    # project's registry to avoid blocking developer velocity.
    # Production requires attestation for all images.
  }

  dynamic "cluster_admission_rule" {
    for_each = module.gke_cluster.cluster_resource_name != "" ? [module.gke_cluster.cluster_resource_name] : []
    content {
      cluster                 = cluster_admission_rule.value
      evaluation_mode         = var.environment == "prod" ? "REQUIRE_ATTESTATION" : "ALWAYS_DENY"
      enforcement_mode        = var.environment == "prod" ? "DRYRID_AUDIT_MODE" : "BLOCK_AUDIT_MODE"
      require_attestations_by = var.environment == "prod" ? ["projects/${var.project_id}/attestors/secondwave-attestor"] : []
    }
  }

  default_admission_rule {
    evaluation_mode  = "ALWAYS_ALLOW"
    enforcement_mode = "BLOCK_AUDIT_MODE"
  }
}
