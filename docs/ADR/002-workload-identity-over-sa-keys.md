# ADR-002: Workload Identity over Service Account Keys

## Status

Accepted

## Context

Kubernetes workloads on GKE need to authenticate to GCP APIs (Secret Manager, Cloud SQL, GCS, Pub/Sub, etc.). The legacy approach is to create a GCP service account key (JSON), store it as a Kubernetes Secret, and mount it into pods. This pattern has caused numerous security incidents in the industry.

## Decision

We use **GKE Workload Identity** (WI) for all pod-to-GCP authentication. No static service account keys are generated or stored in the cluster.

### Architecture

```
┌──────────┐      ┌──────────────┐      ┌──────────────┐
│  Pod     │─────▶│  GKE Metadata │─────▶│  GCP IAM     │
│ (KSA)    │      │  Server       │      │  (GSA)       │
└──────────┘      └──────────────┘      └──────────────┘
     │                   │                     │
     │                   │                     │
     ▼                   ▼                     ▼
  No keys            Auto token              IAM binding
  in pod             exchange                KSA → GSA
```

### How It Works

1. Each workload gets a dedicated Kubernetes service account (KSA).
2. An IAM binding allows the KSA to impersonate a GCP service account (GSA).
3. GKE's metadata server intercepts token requests and exchanges the pod's identity for a GCP access token.
4. The token is short-lived (1 hour default) and automatically refreshed.

## Rationale

### Security

1. **No static credentials**: GCP SA keys are the #1 cause of cloud credential leaks. They end up in CI logs, Docker image layers, and git repositories. WI eliminates this class of vulnerability entirely.

2. **Automatic rotation**: Tokens are short-lived and rotated transparently. A leaked token is valid for at most 1 hour.

3. **Fine-grained scoping**: Each KSA gets access to exactly one GSA. Compromising one pod does not expose other workloads' credentials.

4. **Revocation**: Removing the IAM binding immediately revokes access. No stale keys to track.

### Operational

1. **No secret rotation**: With static keys, you must rotate them regularly and update every Secret. WI has no keys to rotate.

2. **Audit trail**: Cloud Audit Logs show which KSA (via service account impersonation) accessed which resource, providing a complete chain of custody.

3. **GitOps-friendly**: The KSA annotations are declarative and version-controlled.

## Consequences

1. **GKE-only**: Workload Identity only works on GKE. Migrating to another Kubernetes platform would require a different auth mechanism.
2. **Metadata server dependency**: Pods must trust the GKE metadata server (the `kube-env` metadata endpoint is disabled).
3. **External workloads**: Non-GKE workloads (Cloud Run, GCE) cannot use WI. They use OIDC federation or workload identity federation instead.

## Alternatives Considered

- **GCP SA keys in Kubernetes Secrets**: Rejected — insecure, hard to rotate, and frequently leaked.
- **GCP Secret Manager CSI Driver**: Rejected because ESO provides push-based sync (for secret rotation) and native Kubernetes Secret objects that existing applications can consume without changes.
- **Workload Identity Federation**: Suitable for non-GKE clusters (e.g., EKS, on-prem). Overkill for a GKE-only platform.

## Related

- [ADR-004: External Secrets over CSI Driver](./004-external-secrets-over-csi-driver.md)
