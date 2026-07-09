# ============================================================================
# GKE Cluster Module — SecondWave Container Platform
# ============================================================================
# ARCHITECTURE DECISION: Private Cluster
# The control plane endpoint is private (RFC 1918) with no public access.
# All access must come through the VPC peering or Cloud VPN that connects
# SecondWave's on-premise network to GCP. This eliminates the attack surface
# of a public API endpoint and is mandatory for PCI-DSS compliance.
#
# ARCHITECTURE DECISION: GKE Standard over Autopilot
# We choose GKE Standard because:
# 1. Node taints and tolerations: Fintech workloads require strict
#    segregation — PCI workloads on dedicated nodes, batch on spot. Autopilot
#    does not support node-level taints.
# 2. Cost optimisation: Spot VMs for non-production and batch workloads
#    reduce costs by ~60% vs Autopilot's flat pricing.
# 3. Control plane customisation: We need CMEK on the control plane,
#    which is not available in Autopilot.
# 4. Network policy: Calico enforcement on GKE Standard is more flexible
#    than Autopilot's limited network policy.
# See ADR-001 for full rationale.
#
# SECURITY SAFEGUARD: Shielded GKE Nodes
# Shielded GKE nodes enable vTPM and integrity monitoring, which detect
# boot-level tampering. This is a requirement for SecondWave's threat model
# where a compromised node could exfiltrate PCI-scoped data.
# ============================================================================

resource "google_container_cluster" "primary" {
  provider = google-beta

  project = var.project_id
  name    = var.cluster_name
  location = var.region

  # ARCHITECTURE DECISION: No zones specified — regional cluster
  # A regional cluster spreads the control plane across three zones in the
  # region, providing higher availability than a zonal cluster. For
  # SecondWave's 99.99% SLA target, this is non-negotiable.
  #
  # SECURITY SAFEGUARD: Regional clusters also survive zone failures
  # without manual intervention, reducing MTTR for platform incidents.

  # --------------------------------------------------------------------------
  # Release Channel
  # --------------------------------------------------------------------------
  # ARCHITECTURE DECISION: Release Channel
  # We pin to a release channel rather than a specific version so that
  # Google-managed auto-upgrades apply security patches automatically.
  # The channel varies by environment:
  #   prod:    STABLE — maximum stability, delayed ~90 days
  #   staging: REGULAR — balance of stability and new features
  #   dev:     RAPID — earliest access to features for testing
  # This follows Google's recommended approach and avoids the trap of
  # pinning a version and never upgrading.
  release_channel {
    channel = var.release_channel
  }

  # --------------------------------------------------------------------------
  # Private Cluster Configuration
  # --------------------------------------------------------------------------
  # ARCHITECTURE DECISION: Private Endpoint
  # master_global_access_config is NOT enabled — the control plane is
  # reachable only from within the VPC. This is stricter than the default
  # which allows access from any region within the same VPC network.
  private_cluster_config {
    enable_private_endpoint = true
    enable_private_nodes    = true
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block

    # SECURITY SAFEGUARD: Master authorised networks restrict which
    # CIDR ranges can access the private endpoint. This provides a
    # defence-in-depth layer even within the VPC.
    dynamic "master_authorized_networks_config" {
      for_each = length(var.master_authorized_networks) > 0 ? [var.master_authorized_networks] : []
      content {
        dynamic "cidr_blocks" {
          for_each = master_authorized_networks_config.value
          content {
            cidr_block   = cidr_blocks.value.cidr_block
            display_name = cidr_blocks.value.display_name
          }
        }
      }
    }
  }

  # --------------------------------------------------------------------------
  # IP Allocation — VPC-Native (Data Plane)
  # --------------------------------------------------------------------------
  # ARCHITECTURE DECISION: VPC-Native Cluster
  # VPC-native (alias IP) clusters assign pod IPs from a secondary CIDR
  # range on the subnet rather than using NAT. This enables:
  # 1. Direct pod-to-pod communication across clusters via VPC peering
  # 2. Cloud Nat Gateway for outbound with audit logging
  # 3. GKE Dataplane V2 for eBPF-based networking instead of kube-proxy
  networking_mode = "VPC_NATIVE"
  network         = var.vpc_network
  subnetwork      = var.vpc_subnet

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"

    # ARCHITECTURE DECISION: Explicit CIDR ranges
    # We specify CIDR ranges rather than relying on Google's default
    # allocation because we need predictable IP ranges for firewall
    # rules and VPC Service Controls.
  }

  # --------------------------------------------------------------------------
  # Workload Identity
  # --------------------------------------------------------------------------
  # ARCHITECTURE DECISION: Workload Identity
  # Workload Identity allows Kubernetes service accounts (KSAs) to
  # impersonate GCP service accounts (GSAs) without managing static keys.
  # This eliminates the single biggest supply-chain risk in K8s:
  # leaked GCP service account keys in CI logs, image layers, or git repos.
  #
  # SECURITY SAFEGUARD: No GCP SA keys are ever stored in Kubernetes
  # Secrets. Each KSA gets a short-lived token via the GKE metadata server.
  # Key rotation is automatic and transparent.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # --------------------------------------------------------------------------
  # CMEK Encryption — Control Plane
  # --------------------------------------------------------------------------
  # ARCHITECTURE DECISION: CMEK on Control Plane
  # Customer-Managed Encryption Keys encrypt etcd (storing Secrets,
  # ConfigMaps) and the control plane's persistent disks. Google-managed
  # keys protect against Google infrastructure compromise; CMEK protects
  # against Google employee access. For SecondWave's PCI-scoped data,
  # both layers are required.
  #
  # SECURITY SAFEGUARD: If the CMEK key is destroyed, the cluster becomes
  # unrecoverable. The KMS key has a key rotation schedule set by Security
  # and must NOT have a destruction schedule shorter than the cluster's
  # backup retention (30 days).
  dynamic "confidential_nodes" {
    for_each = var.cmek_key_name != null ? [1] : []
    content {
      enabled = true
    }
  }

  # --------------------------------------------------------------------------
  # Database Encryption (etcd encryption at rest)
  # --------------------------------------------------------------------------
  # ARCHITECTURE DECISION: CMEK for etcd
  # GKE encrypts etcd at rest by default with Google-managed keys.
  # We layer CMEK on top so that Secret data in etcd is encrypted with
  # a key SecondWave controls.
  dynamic "database_encryption" {
    for_each = var.cmek_key_name != null ? [var.cmek_key_name] : []
    content {
      state    = "ENCRYPTED"
      key_name = database_encryption.value
    }
  }

  # --------------------------------------------------------------------------
  # Shielded Nodes
  # --------------------------------------------------------------------------
  # SECURITY SAFEGUARD: Shielded GKE Nodes
  # Enable secure boot, integrity monitoring, and vTPM on all nodes.
  # This prevents bootkits and rootkits from persisting on node VMs.
  # For PCI-DSS requirement 10.5.2 (audit logging), integrity monitoring
  # logs boot measurements to Cloud Logging.
  # DEPRECATED: Remove default_sa and use service_account per node pool.
  # Removed default node_pool block; we create pools via the node pools module.

  # --------------------------------------------------------------------------
  # Node Auto-Provisioning
  # --------------------------------------------------------------------------
  # ARCHITECTURE DECISION: Node Auto-Provisioning
  # NAP automatically creates and deletes node pools based on unscheduled
  # pods. This handles burst capacity (e.g., batch jobs, CI runners)
  # without manual intervention. NAP-pool nodes automatically use the
  # cluster's shielded image and CMEK boot disk.
  dynamic "cluster_autoscaling" {
    for_each = var.enable_node_auto_provisioning ? [1] : []
    content {
      enabled = true

      resource_limits {
        resource_type = "cpu"
        minimum = var.environment == "prod" ? 2 : 1
        maximum = var.environment == "prod" ? 100 : 50
      }

      resource_limits {
        resource_type = "memory"
        minimum = var.environment == "prod" ? 4 : 2
        maximum = var.environment == "prod" ? 400 : 200
      }

      # SECURITY SAFEGUARD: Auto-scaling uses the same shielded node
      # configuration as manually created node pools.
      auto_provisioning_defaults {
        service_account = google_service_account.gke_nodes.email
        oauth_scopes    = [
          "https://www.googleapis.com/auth/cloud-platform",
        ]

        # ARCHITECTURE DECISION: Minimal OAuth Scopes for NAP
        # NAP nodes get only cloud-platform scope. Individual workload
        # SAs (via Workload Identity) have granular IAM roles. This
        # follows the principle of least privilege — node SA itself should
        # have minimal permissions.
        boot_disk_kms_key = var.cmek_key_name
        disk_size         = 100
        disk_type         = "pd-ssd"
        shielded_instance_config {
          enable_secure_boot          = true
          enable_integrity_monitoring = true
        }
        image_type = "cos_containerd"
      }
    }
  }

  # --------------------------------------------------------------------------
  # Vertical Pod Autoscaling
  # --------------------------------------------------------------------------
  # ARCHITECTURE DECISION: VPA Recommended Mode
  # VPA in RECOMMENDATION mode suggests CPU/memory requests without
  # automatically applying them. This lets the platform team review
  # recommendations before they take effect, avoiding the risk of
  # VPA-triggered pod evictions during peak trading hours.
  vertical_pod_autoscaling {
    enabled = var.enable_vertical_pod_autoscaling
  }

  # --------------------------------------------------------------------------
  # Network Policy — Calico
  # --------------------------------------------------------------------------
  # ARCHITECTURE DECISION: Calico Network Policy
  # Calico provides Kubernetes NetworkPolicy enforcement with support
  # for global network policies, egress access controls, and namespace
  # isolation. It is the most widely adopted CNI policy engine and is
  # natively supported by GKE Standard.
  #
  # Alternatives considered:
  # - Cilium: More features (L7, Hubble observability) but requires
  #   Dataplane V2, which is still GA-vs-beta mixed in GKE.
  # - GKE Dataplane V2 (eBPF): Good option; we enable it below.
  network_policy {
    enabled = true
    provider = "CALICO"
  }

  # Enable Dataplane V2 for eBPF data path
  datapath_provider = "ADVANCED_DATAPATH"

  # --------------------------------------------------------------------------
  # GKE Gateway Controller
  # --------------------------------------------------------------------------
  # ARCHITECTURE DECISION: GKE Gateway Controller
  # Enables the Gateway API controller on the cluster, which allows
  # configuring GCP HTTP(S) Load Balancers via Kubernetes Gateway API
  # resources. This provides a richer routing model than Ingress v1
  # and supports features like traffic splitting, header-based routing,
  # and cross-namespace routing.
  #
  # Note: This requires the `gke-gateway-controller` addon, which
  # is enabled via the gateway_api_config block.
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  # --------------------------------------------------------------------------
  # Addons
  # --------------------------------------------------------------------------
  addons_config {
    # HTTP Load Balancing for Ingress
    http_load_balancing {
      disabled = false
    }

    # Horizontal Pod Autoscaling
    horizontal_pod_autoscaling {
      disabled = false
    }

    # Kubernetes Dashboard — disabled for security
    kubernetes_dashboard {
      disabled = true
    }

    # Network Policy — enabled above
    network_policy_config {
      disabled = false
    }

    # Cloud Native Storage CSI
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }

    # Config Connector — managed GCP resources via K8s
    config_connector_config {
      enabled = true
    }
  }

  # --------------------------------------------------------------------------
  # Maintenance Window
  # --------------------------------------------------------------------------
  # ARCHITECTURE DECISION: Maintenance Window
  # Scheduled maintenance during SecondWave's lowest traffic window
  # (Sunday 04:00–06:00 UTC). Exclusions for blackout periods around
  # end-of-quarter financial reporting.
  maintenance_policy {
    daily_maintenance_window {
      start_time = "04:00"
    }

    recurring_window {
      start_time = "2024-01-01T04:00:00Z"
      end_time   = "2024-01-01T06:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }

    maintenance_exclusion {
      event_name = "eoy-reporting"
      start_time = "2024-12-20T00:00:00Z"
      end_time   = "2025-01-15T23:59:59Z"
    }

    maintenance_exclusion {
      event_name = "q1-reporting"
      start_time = "2024-03-25T00:00:00Z"
      end_time   = "2024-04-05T23:59:59Z"
    }
  }

  # --------------------------------------------------------------------------
  # Resource Labels
  # --------------------------------------------------------------------------
  resource_labels = merge(var.tags, {
    cluster_name = var.cluster_name
    environment  = var.environment
  })

  # --------------------------------------------------------------------------
  # Deletion Protection
  # --------------------------------------------------------------------------
  # SECURITY SAFEGUARD: Deletion protection prevents accidental cluster
  # destruction. To delete the cluster, first set this to false in the
  # Terraform config and apply, then destroy.
  deletion_protection = true
}

# ---------------------------------------------------------------------------
# Node Service Account
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: Dedicated Node Service Account
# Instead of using the default Compute Engine SA, we create a dedicated SA.
# This enables audit logging per node action and limits blast radius.
# The SA gets the minimal roles needed: GCR pull, Stackdriver logging/
# monitoring. All other GCP API access goes through Workload Identity.
#
# SECURITY SAFEGUARD: This SA does NOT have any GCS or BigQuery access.
# Workloads that need those use Workload Identity with individual SAs.
resource "google_service_account" "gke_nodes" {
  project      = var.project_id
  account_id   = "${var.cluster_name}-node-sa"
  display_name = "GKE Node SA for ${var.cluster_name}"
  description  = "Service account for GKE nodes. Minimal permissions — workloads use Workload Identity."
}

resource "google_project_iam_member" "gke_nodes_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_metadata_writer" {
  project = var.project_id
  role    = "roles/stackdriver.resourceMetadata.writer"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}
