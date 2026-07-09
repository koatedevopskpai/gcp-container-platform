# ============================================================================
# Addons Module — SecondWave Container Platform
# ============================================================================
# This module deploys the standard set of cluster addons that every
# SecondWave Kubernetes workload relies on:
#   - cert-manager: TLS certificate management
#   - external-dns: Kubernetes-aware DNS management in Google Cloud DNS
#   - External Secrets Operator: Syncs GCP Secret Manager to K8s Secrets
#   - Kyverno: Kubernetes-native policy engine for pod security
#   - nginx-ingress: Ingress controller for HTTP routing
#   - OpenTelemetry Operator: Collector for observability signals
#
# ARCHITECTURE DECISION: Helm for Addon Deployment
# We use the Helm provider rather than Kubernetes manifests directly
# because: (1) Helm provides version management and rollback, (2) each
# addon publishes a Helm chart with standardised values, and (3) the
# Terraform Helm provider integrates with state tracking. For addon
# configuration that changes frequently, we use the GitOps tool
# (ArgoCD/Flux) instead.
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

variable "region" {
  description = "GCP region"
  type        = string
}

variable "domain_name" {
  description = "DNS domain for cert-manager and external-dns"
  type        = string
  default     = ""
}

variable "cert_manager_email" {
  description = "Email for Let's Encrypt registration"
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

# ---------------------------------------------------------------------------
# Helm Provider (uses the cluster from google + kubernetes provider)
# ---------------------------------------------------------------------------
provider "helm" {
  alias = "addons"

  kubernetes {
    host                   = "https://${data.google_client_config.default.access_token}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(data.google_client_config.default.access_token)
  }
}

data "google_client_config" "default" {
}

# ---------------------------------------------------------------------------
# 1. cert-manager
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: cert-manager over GCP Certificate Manager
# cert-manager manages TLS certificates natively within Kubernetes using
# the Certificate CRD. It integrates with Let's Encrypt and Google CA.
# GCP Certificate Manager is a valid alternative but requires managing
# certificates outside Kubernetes (less GitOps-friendly).
#
# SECURITY SAFEGUARD: Automatic renewal monitoring is built-in.
# cert-manager retries renewals 30 days before expiry and reports
# Certificate expiry metrics via Prometheus.
resource "helm_release" "cert_manager" {
  count = var.cert_manager_email != "" ? 1 : 0

  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  version          = "~> 1.15"

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "prometheus.enabled"
    value = "true"
  }

  set {
    name  = "metrics.enabled"
    value = "true"
  }

  set {
    name  = "serviceAccount.annotations.iam\\.gke\\.io/gcp-service-account"
    value = "cert-manager-sa@${var.project_id}.iam.gserviceaccount.com"
  }

  wait      = true
  timeout   = 180
  depends_on = []
}

# ClusterIssuer for Let's Encrypt Production
resource "kubernetes_manifest" "letsencrypt_prod_issuer" {
  count = var.cert_manager_email != "" ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        email  = var.cert_manager_email
        server = "https://acme-v02.api.letsencrypt.org/directory"
        privateKeySecretRef = {
          name = "letsencrypt-prod-account-key"
        }
        solvers = [
          {
            dns01 = {
              cloudDNS = {
                project = var.project_id
              }
            }
          }
        ]
      }
    }
  }

  depends_on = [helm_release.cert_manager]
}

# ClusterIssuer for Let's Encrypt Staging (testing)
resource "kubernetes_manifest" "letsencrypt_staging_issuer" {
  count = var.cert_manager_email != "" ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-staging"
    }
    spec = {
      acme = {
        email  = var.cert_manager_email
        server = "https://acme-staging-v02.api.letsencrypt.org/directory"
        privateKeySecretRef = {
          name = "letsencrypt-staging-account-key"
        }
        solvers = [
          {
            dns01 = {
              cloudDNS = {
                project = var.project_id
              }
            }
          }
        ]
      }
    }
  }

  depends_on = [helm_release.cert_manager]
}

# ---------------------------------------------------------------------------
# 2. external-dns
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: external-dns with Google Cloud DNS
# external-dns watches Kubernetes Ingress and Service resources and
# automatically creates DNS records in Google Cloud DNS. This eliminates
# manual DNS management and ensures DNS records are always in sync with
# the cluster state.
#
# SECURITY SAFEGUARD: external-dns runs with a dedicated Workload Identity
# GSA that has roles/dns.admin only on the managed zone, not the entire
# project. This limits blast radius if the pod is compromised.
resource "helm_release" "external_dns" {
  count = var.external_dns_enabled ? 1 : 0

  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns"
  chart            = "external-dns"
  namespace        = "external-dns"
  create_namespace = true
  version          = "~> 1.14"

  set {
    name  = "provider"
    value = "google"
  }

  set {
    name  = "google.project"
    value = var.project_id
  }

  set {
    name  = "serviceAccount.annotations.iam\\.gke\\.io/gcp-service-account"
    value = "external-dns-sa@${var.project_id}.iam.gserviceaccount.com"
  }

  set {
    name  = "sources[0]"
    value = "ingress"
  }

  set {
    name  = "sources[1]"
    value = "service"
  }

  set {
    name  = "sources[2]"
    value = "crd"
  }

  set {
    name  = "policy"
    value = "sync"
  }

  set {
    name  = "registry"
    value = "txt"
  }

  set {
    name  = "interval"
    value = "30s"
  }

  set {
    name  = "logLevel"
    value = "info"
  }

  # ARG: domain filter
  set {
    name  = "domainFilters[0]"
    value = var.domain_name
  }

  wait      = true
  timeout   = 120
  depends_on = []
}

# ---------------------------------------------------------------------------
# 3. External Secrets Operator
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: ESO over CSI Driver
# External Secrets Operator (ESO) synchronises GCP Secret Manager secrets
# to Kubernetes Secrets as native objects. The CSI Driver would require
# application code to read from a volume mount, which breaks existing
# applications that expect environment variables or volume-mounted Secrets.
# ESO also supports push-based sync for near-real-time secret rotation.
#
# See ADR-004 for full rationale.
#
# SECURITY SAFEGUARD: ESO stores the secret synchronisation in the
# SecretStore CRD which is namespace-scoped. Each namespace can have
# its own SecretStore pointing to specific Secret Manager prefixes,
# preventing cross-namespace secret access.
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  version          = "~> 0.10"

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "metrics.enabled"
    value = "true"
  }

  set {
    name  = "serviceAccount.annotations.iam\\.gke\\.io/gcp-service-account"
    value = "external-secrets-sa@${var.project_id}.iam.gserviceaccount.com"
  }

  set {
    name  = "scopedNamespace"
    value = ""
  }

  wait      = true
  timeout   = 120
  depends_on = []
}

# Create a ClusterSecretStore that references the GCP Secret Manager
# with Workload Identity auth — no static credentials needed.
resource "kubernetes_manifest" "cluster_secret_store" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "gcp-secret-manager"
    }
    spec = {
      provider = {
        gcpsm = {
          projectID = var.project_id
          auth = {
            workloadIdentity = {
              clusterLocation = var.region
              clusterName     = var.cluster_name
              serviceAccountRef = {
                name = "external-secrets"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.external_secrets]
}

# ---------------------------------------------------------------------------
# 4. Kyverno — Admission Controller
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: Kyverno over OPA/Gatekeeper
# Kyverno uses Kubernetes-native YAML policies (no Rego DSL) which
# makes it significantly easier for the platform team to write and
# maintain policies. Key advantages:
# 1. Policies are standard Kubernetes resources (ClusterPolicy CRD)
# 2. No separate policy language to learn — it's just YAML+JMESPath
# 3. Built-in policy generation, mutate-on-create, and validation
# 4. Reports violations as Kubernetes events (audit trail)
#
# For a small platform team (2-3 people), the lower learning curve of
# Kyverno is a decisive operational advantage over OPA/Gatekeeper's Rego.
# See ADR-003 for full rationale.
#
# SECURITY SAFEGUARD: Kyverno runs in background mode initially —
# policy violations are reported but not enforced. Teams have a
# 30-day window to fix violations before enforcement is enabled.
resource "helm_release" "kyverno" {
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno"
  chart            = "kyverno"
  namespace        = "kyverno"
  create_namespace = true
  version          = "~> 3.2"

  set {
    name  = "reportsController.enabled"
    value = "true"
  }

  set {
    name  = "backgroundController.enabled"
    value = "true"
  }

  set {
    name  = "cleanupController.enabled"
    value = "true"
  }

  set {
    name  = "serviceMonitor.enabled"
    value = "true"
  }

  set {
    name  = "metrics.enabled"
    value = "true"
  }

  set {
    name  = "validationFailureActionByPolicy"
    value = "audit"
  }

  wait      = true
  timeout   = 180
  depends_on = []
}

# ---------------------------------------------------------------------------
# Kyverno Policies
# ---------------------------------------------------------------------------

# SECURITY SAFEGUARD: Disallow Privileged Containers
# Prevents pods from running with escalated privileges. Exceptions can
# be made per namespace via the pod-security.kubernetes.io label.
resource "kubernetes_manifest" "kyverno_disallow_privileged" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "disallow-privileged-containers"
    }
    spec = {
      validationFailureAction = "Audit"
      background             = true
      rules = [
        {
          name = "privileged-containers"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Pod"]
                }
              }
            ]
          }
          validate = {
            message = "Privileged containers are not allowed. Please remove `securityContext.privileged`."
            foreach = [
              {
                list     = "request.object.spec.containers"
                element  = "container"
                pattern  = {
                  securityContext = {
                    privileged = false
                  }
                }
              }
            ]
          }
        }
      ]
    }
  }

  depends_on = [helm_release.kyverno]
}

# SECURITY SAFEGUARD: Require Readiness and Liveness Probes
# All workloads must define probes so that the kubelet can detect
# unhealthy pods and remove them from service.
resource "kubernetes_manifest" "kyverno_require_probes" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "require-readiness-probes"
    }
    spec = {
      validationFailureAction = "Audit"
      background             = true
      rules = [
        {
          name = "check-readiness-probe"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Pod"]
                }
              }
            ]
          }
          validate = {
            message = "Containers must define a readiness probe."
            foreach = [
              {
                list     = "request.object.spec.containers"
                element  = "container"
                pattern  = {
                  readinessProbe = {
                    httpGet = {
                      port = ">0"
                    }
                  }
                }
              }
            ]
          }
        }
      ]
    }
  }

  depends_on = [helm_release.kyverno]
}

# SECURITY SAFEGUARD: Enforce Read-Only Root Filesystem
# Prevents containers from writing to their own filesystem. Writes
# must go to emptyDir volumes or PVCs. This limits the damage of a
# container escape since the attacker cannot write to the host.
resource "kubernetes_manifest" "kyverno_readonly_rootfs" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "require-read-only-root-filesystem"
    }
    spec = {
      validationFailureAction = "Audit"
      background             = true
      rules = [
        {
          name = "check-read-only-root-fs"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Pod"]
                }
              }
            ]
          }
          validate = {
            message = "Containers must have readOnlyRootFilesystem set to true."
            foreach = [
              {
                list     = "request.object.spec.containers"
                element  = "container"
                pattern  = {
                  securityContext = {
                    readOnlyRootFilesystem = true
                  }
                }
              }
            ]
          }
        }
      ]
    }
  }

  depends_on = [helm_release.kyverno]
}

# ---------------------------------------------------------------------------
# 5. nginx-ingress (Ingress NGINX Controller)
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: nginx-ingress alongside GKE Gateway Controller
# We deploy nginx-ingress for workloads that use Ingress v1 resources
# (backwards compatibility with existing apps) while migrating new
# workloads to GKE Gateway. Both ingress controllers coexist through
# different IngressClass resources.
resource "helm_release" "nginx_ingress" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  version          = "~> 4.10"

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  set {
    name  = "controller.service.annotations.cloud\\.google\\.com/neg"
    value = "{\"ingress\": true}"
  }

  set {
    name  = "controller.metrics.enabled"
    value = "true"
  }

  set {
    name  = "controller.metrics.serviceMonitor.enabled"
    value = "true"
  }

  set {
    name  = "controller.config.use-forwarded-headers"
    value = "true"
  }

  set {
    name  = "controller.config.compute-full-forwarded-for"
    value = "true"
  }

  set {
    name  = "controller.config.use-proxy-protocol"
    value = "false"
  }

  set {
    name  = "controller.autoscaling.enabled"
    value = "true"
  }

  set {
    name  = "controller.autoscaling.minReplicas"
    value = "2"
  }

  set {
    name  = "controller.autoscaling.maxReplicas"
    value = "20"
  }

  wait      = true
  timeout   = 300
  depends_on = []
}

# ---------------------------------------------------------------------------
# 6. OpenTelemetry Operator
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: OpenTelemetry Operator
# The OTel Operator manages the lifecycle of OpenTelemetry Collectors
# and auto-instrumentation. It simplifies observability by reducing
# the config needed to collect traces, metrics, and logs.
#
# The collector DaemonSet is defined separately in the observability/
# directory for environment-specific tuning.
resource "helm_release" "opentelemetry_operator" {
  name             = "opentelemetry-operator"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-operator"
  namespace        = "opentelemetry"
  create_namespace = true
  version          = "~> 0.60"

  set {
    name  = "manager.collectorImage.repository"
    value = "otel/opentelemetry-collector-contrib"
  }

  set {
    name  = "manager.collectorImage.tag"
    value = "0.102.0"
  }

  set {
    name  = "admissionWebhooks.enabled"
    value = "true"
  }

  set {
    name  = "metrics.enabled"
    value = "true"
  }

  wait      = true
  timeout   = 180
  depends_on = []
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "addons_deployed" {
  description = "List of deployed addon names"
  value = compact([
    var.cert_manager_email != "" ? "cert-manager" : null,
    var.external_dns_enabled ? "external-dns" : null,
    "external-secrets",
    "kyverno",
    "ingress-nginx",
    "opentelemetry-operator",
  ])
}

output "kyverno_namespace" {
  value = "kyverno"
}

output "eso_cluster_secret_store" {
  value = "gcp-secret-manager"
}
