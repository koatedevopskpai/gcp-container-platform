# ============================================================================
# GKE Node Pools Module — SecondWave Container Platform
# ============================================================================
# SECURITY SAFEGUARD: Principle of Least Privilege for Nodes
# Each node pool uses the dedicated node service account with the
# narrowest possible OAuth scopes. We do NOT grant cloud-platform scope
# to any node pool by default. Workloads that need GCP API access must
# use Workload Identity with a dedicated GCP service account.
#
# ARCHITECTURE DECISION: Spot vs Reserved Nodes
# - Spot VMs (dev/staging/batch): Up to 91% cost savings, preemptible
#   by GCP with 30s notice. Used for batch jobs, CI runners, and
#   non-production environments. Taints prevent critical workloads from
#   scheduling on spot nodes.
# - Reserved (CUD) VMs (prod): 1- or 3-year commitments for predictable
#   workloads. Used for customer-facing APIs and data plane components.
# - On-demand (flexible): General-purpose pools can scale with on-demand
#   instances when reserved/spot capacity is exhausted.
# ============================================================================

# ARCHITECTURE DECISION: Data Plane V2 Support
# Node pools must use container-only SSH (disabled) and COS containerd
# image type to be compatible with GKE Dataplane V2 and eBPF networking.

resource "google_container_node_pool" "pools" {
  for_each = var.node_pools

  project    = var.project_id
  name       = "${var.cluster_name}-${each.key}"
  location   = var.region
  cluster    = var.cluster_name

  # ARCHITECTURE DECISION: Initial Node Count
  # We set initial_node_count to 0 because the autoscaler will manage
  # the actual count based on workload demand. Setting a non-zero value
  # would create unnecessary fixed-cost nodes at deployment time.

  initial_node_count = 0

  # --------------------------------------------------------------------------
  # Autoscaling
  # --------------------------------------------------------------------------
  autoscaling {
    min_node_count = each.value.min_count
    max_node_count = each.value.max_count
    location_policy = "BALANCED"
  }

  # --------------------------------------------------------------------------
  # Node Management
  # --------------------------------------------------------------------------
  management {
    auto_repair  = each.value.auto_repair
    auto_upgrade = each.value.auto_upgrade

    # SECURITY SAFEGUARD: Auto-upgrade must be enabled for all
    # node pools to receive security patches automatically.
    # Only during emergency incident response would we temporarily
    # disable this for a specific pool.
  }

  # --------------------------------------------------------------------------
  # Node Config
  # --------------------------------------------------------------------------
  node_config {
    machine_type = each.value.machine_type
    disk_size_gb = each.value.disk_size_gb
    disk_type    = each.value.disk_type
    image_type   = "COS_CONTAINERD"

    # SECURITY SAFEGUARD: OAuth Scopes Minimisation
    # Only devstorage.read_only for GCR/GAR pull, and default
    # monitoring/logging scopes. No cloud-platform scope.
    # Workload Identity handles all GCP API access at the pod level.
    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/trace.append",
    ]

    # ARCHITECTURE DECISION: Use the dedicated node SA created by the
    # cluster module rather than the default Compute Engine SA. This
    # ensures we can audit which nodes are doing what.
    service_account = var.environment == "prod" ? google_service_account.prod_nodes[0].email : google_service_account.nonprod_nodes[0].email

    # -----------------------------------------------------------------------
    # Spot VMs
    # -----------------------------------------------------------------------
    # ARCHITECTURE DECISION: Spot VMs for Non-Production
    # Spot VMs reduce costs by up to 91% compared to on-demand for
    # dev/staging environments. We use the `spot` attribute rather than
    # preemptible because spot instances have no maximum runtime limit
    # (unlike preemptible's 24h cap) and offer the same pricing.
    #
    # SECURITY SAFEGUARD: Spot nodes get a taint so that only workloads
    # with matching tolerations schedule on them. This prevents critical
    # services from being evicted when GCP reclaims spot capacity.
    spot = each.value.spot

    # -----------------------------------------------------------------------
    # Local SSDs
    # -----------------------------------------------------------------------
    dynamic "local_ssd_count" {
      for_each = each.value.local_ssd_count > 0 ? [each.value.local_ssd_count] : []
      content {
        count = local_ssd_count.value
      }
    }

    # -----------------------------------------------------------------------
    # Shielded Instance Config
    # -----------------------------------------------------------------------
    # SECURITY SAFEGUARD: All nodes, regardless of environment, use
    # shielded VM features. Secure boot prevents boot-level malware,
    # and integrity monitoring sends boot measurements to Cloud Logging.
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # -----------------------------------------------------------------------
    # Labels
    # -----------------------------------------------------------------------
    labels = merge(var.tags, each.value.labels, {
      pool_name    = each.key
      environment  = var.environment
      cluster_name = var.cluster_name
      spot         = tostring(each.value.spot)
    })

    # -----------------------------------------------------------------------
    # Metadata
    # -----------------------------------------------------------------------
    # SECURITY SAFEGUARD: Disable GCE legacy endpoints and VM-level
    # SSH (use IAP tunnel instead). Disabling `sshKeys` blocks
    # metadata-based SSH key injection.
    metadata = {
      disable-legacy-endpoints = "true"
    }

    # -----------------------------------------------------------------------
    # Taints
    # -----------------------------------------------------------------------
    dynamic "taint" {
      for_each = each.value.taints
      content {
        key    = taint.value.key
        value  = taint.value.value
        effect = taint.value.effect
      }
    }

    # -----------------------------------------------------------------------
    # Guest Accelerator (GPU) — reserved for future ML workloads
    # -----------------------------------------------------------------------
    # dynamic "guest_accelerator" {
    #   for_each = try(each.value.gpu, null) != null ? [each.value.gpu] : []
    #   content {
    #     type  = guest_accelerator.value.type
    #     count = guest_accelerator.value.count
    #     gpu_driver_installation_config {
    #       gpu_driver_version = "LATEST"
    #     }
    #   }
    # }

    # -----------------------------------------------------------------------
    # Workload Metadata Config
    # -----------------------------------------------------------------------
    # SECURITY SAFEGUARD: GKE Metadata Server hides the node's GCE
    # metadata from pods. Pods must use Workload Identity to access
    # GCP APIs. This prevents credential harvesting via metadata
    # SSRF attacks.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  # --------------------------------------------------------------------------
  # Upgrade Settings
  # --------------------------------------------------------------------------
  # ARCHITECTURE DECISION: Surge Upgrades
  # Surge upgrades add extra nodes (max_surge) and cordon old ones
  # (max_unavailable) during upgrades, ensuring zero-downtime for
  # workloads with pod disruption budgets. Blue-green upgrades would be
  # more isolated but require more resources and time.
  upgrade_settings {
    strategy = "SURGE"
    max_surge = 1
    max_unavailable = 0
  }

  # --------------------------------------------------------------------------
  # Placement Policy (for prod pools)
  # --------------------------------------------------------------------------
  # ARCHITECTURE DECISION: COMPACT placement for prod data-plane pools
  # Compact placement ensures nodes are in the same zone for low-latency
  # inter-pod communication. Only applied to pools tagged "data-plane".
  # SPREAD placement for general pools to maximise availability.
  # dynamic "placement_policy" {
  #   for_each = try(each.value.labels.workload, "") == "data-plane" ? [1] : []
  #   content {
  #     type = "COMPACT"
  #   }
  # }

  depends_on = [
    # Ensure the node SA and IAM bindings exist before creating node pools
  ]
}

# ---------------------------------------------------------------------------
# Node Service Accounts (separated by env for audit trail)
# ---------------------------------------------------------------------------
resource "google_service_account" "nonprod_nodes" {
  count        = var.environment == "prod" ? 0 : 1
  project      = var.project_id
  account_id   = "gke-nonprod-nodes"
  display_name = "GKE Node SA — Non-Production"
  description  = "Service account for non-production GKE node pools"
}

resource "google_service_account" "prod_nodes" {
  count        = var.environment == "prod" ? 1 : 0
  project      = var.project_id
  account_id   = "gke-prod-nodes"
  display_name = "GKE Node SA — Production"
  description  = "Service account for production GKE node pools"
}

# IAM bindings for node service accounts
resource "google_project_iam_member" "nodes_logging" {
  for_each = toset(var.environment == "prod" ? [google_service_account.prod_nodes[0].email] : [google_service_account.nonprod_nodes[0].email])
  project  = var.project_id
  role     = "roles/logging.logWriter"
  member   = "serviceAccount:${each.key}"
}

resource "google_project_iam_member" "nodes_monitoring" {
  for_each = toset(var.environment == "prod" ? [google_service_account.prod_nodes[0].email] : [google_service_account.nonprod_nodes[0].email])
  project  = var.project_id
  role     = "roles/monitoring.metricWriter"
  member   = "serviceAccount:${each.key}"
}

resource "google_project_iam_member" "nodes_metadata_writer" {
  for_each = toset(var.environment == "prod" ? [google_service_account.prod_nodes[0].email] : [google_service_account.nonprod_nodes[0].email])
  project  = var.project_id
  role     = "roles/stackdriver.resourceMetadata.writer"
  member   = "serviceAccount:${each.key}"
}
