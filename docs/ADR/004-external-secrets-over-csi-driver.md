# ADR-004: External Secrets Operator over GCP Secret Manager CSI Driver

## Status

Accepted

## Context

Kubernetes workloads need access to secrets stored in GCP Secret Manager (database credentials, API keys, TLS certificates). Two primary options exist:

1. **External Secrets Operator (ESO)**: Synchronises Secret Manager entries to Kubernetes Secrets as native objects.
2. **GCP Secret Store CSI Driver**: Mounts secrets as volumes; pods read from a filesystem path.

## Decision

We choose **External Secrets Operator** with push-based sync.

## Rationale

### 1. Native Kubernetes Secret Objects

ESO creates standard `kind: Secret` objects that workloads consume via:
- Environment variables
- Volume mounts (`subPath`)
- Standard volume mounts

The CSI Driver requires all workloads to mount a CSI volume, which means:
- Applications must be aware they're reading from a CSI driver (different mount path)
- Cannot use environment variables (most common pattern)
- Cannot use `subPath` for single-file injection

For SecondWave, most workloads expect secrets as environment variables or standard volume mounts. ESO creates native Secrets that work with any application without modification.

### 2. Push-Based Sync for Secret Rotation

ESO supports **push-based sync** via webhooks or polling at configurable intervals:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
spec:
  refreshInterval: "30s"  # Poll every 30 seconds
```

When a secret is updated in Secret Manager, ESO detects the change (via poll interval or webhook) and updates the Kubernetes Secret within seconds. Pods that mount the Secret as a volume see the update automatically (via the inotify mechanism).

The CSI Driver only refreshes secrets when the pod restarts (on CSI driver versions before v1.0). For workloads that need near-real-time secret rotation without pod restart, ESO's push-based sync is essential.

### 3. Secret Rotation Without Pod Restart

ESO synchronises secrets to native Kubernetes Secrets. When the Secret is updated, pods that mount it as a volume see the new content within the kubelet sync period (~60s). Pods that use environment variables need a restart, but the Secret object is updated regardless.

With the CSI Driver (pre-v1.0), the Secret content is only updated when the pod is recreated. This makes rotation-dependent workflows (e.g., rotating database credentials without downtime) impossible.

### 4. GitOps Integration

ESO's `ExternalSecret` CRD is a Kubernetes resource that integrates with ArgoCD/Flux natively. The secret template and store reference are declarative and version-controlled.

The CSI Driver requires provider-specific configurations on the `SecretProviderClass` CRD, which is less portable across environments.

## Consequences

1. **Additional component**: ESO is an extra controller to maintain (vs. CSI Driver which is a CSI plugin).
2. **Secret data in etcd**: Because ESO creates native Kubernetes Secrets, the secret data is stored in etcd (encrypted at rest via CMEK). The CSI Driver does not store secrets in etcd.
3. **Network dependency**: ESO needs network access to GCP Secret Manager API. The CSI Driver also needs this, so no difference in failure mode.

## Alternatives Considered

- **GCP Secret Manager CSI Driver**: Rejected for lack of push-based sync and inability to use environment variables.
- **Bitnami Sealed Secrets**: Requires Git-based workflows for secret updates; no push sync from Secret Manager.
- **Helm Secrets / SOPS**: Client-side encryption, not suitable for runtime secret consumption.
- **Vault (HashiCorp)**: Overkill for a GKE-only platform; Vault's agent injector adds operational complexity without benefits over ESO.

## Related

- [ADR-002: Workload Identity over SA Keys](./002-workload-identity-over-sa-keys.md)
