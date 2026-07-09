# ADR-001: GKE Standard over Autopilot

## Status

Accepted

## Context

SecondWave requires a Kubernetes platform for fintech workloads with PCI-DSS compliance. GKE offers two modes: Standard (full control over nodes) and Autopilot (fully managed node infrastructure). The platform team (2-3 people) needs to balance operational overhead against security control.

## Decision

We choose **GKE Standard** with the following rationale:

### 1. Node-Level Taints and Tolerations

Standard allows per-node-pool taints. This is essential for workload segregation:
- **PCI workloads** on dedicated nodes with `NoSchedule` taint
- **Batch/CI workloads** on spot VMs with `PreferNoSchedule`
- **Data plane** on reserved CUD instances with `NoExecute`

Autopilot does not support node-level taints. Workloads are scheduled on a shared node pool, making PCI compliance scoping impossible.

### 2. CMEK on Control Plane

Standard supports Customer-Managed Encryption Keys on both the control plane (etcd) and data plane (boot disks). Autopilot only supports CMEK on data plane. For SecondWave's PCI-scoped data, both layers must be encrypted with SecondWave-controlled keys.

### 3. Cost Optimisation

| Workload Type | Standard (Spot) | Autopilot |
|---|---|---|
| Dev/Staging (always-on) | ~$200/month (3x e2-standard-2 spot) | ~$450/month (min 2 vCPU per pod) |
| Batch (intermittent) | ~60% cost vs on-demand | Same as on-demand |
| Prod (3-year CUD) | 57% discount via CUD | No committed-use discounts |

Autopilot's per-pod billing (vCPU, memory, ephemeral storage) is more expensive for long-running pods and offers no spot pricing.

### 4. Network Policy

Standard supports Calico network policy (enforced at node level via eBPF with Dataplane V2). Autopilot uses a simplified network policy model that does not support egress policy enforcement, which is required for SecondWave's zero-trust networking.

### 5. Node Auto-Provisioning

Standard with NAP provides automatic node pool scaling while retaining control over node configuration (machine type, disk type, taints). Autopilot delegates all node decisions to Google, which may schedule PCI workloads on suboptimal hardware.

## Consequences

1. **Operational overhead**: The platform team must manage node pool sizing, upgrades, and spot VM interruptions.
2. **Flexibility**: Full control over node configuration enables cost optimisation and security isolation that Autopilot cannot match.
3. **Upgrade complexity**: Node pool upgrades require surge or blue-green strategies, which Autopilot handles automatically.

## Alternatives Considered

- **GKE Autopilot**: Rejected due to lack of taints, CMEK on control plane, and calico network policy.
- **EKS (AWS)**: SecondWave's primary cloud is GCP; managing a multi-cloud Kubernetes platform for a single workload is not justified.
- **AKS (Azure)**: Same as EKS — no strategic benefit.
- **Vanilla Kubernetes on GCE**: Significantly higher operational overhead with no benefit over GKE Standard.

## Related

- [ADR-002: Workload Identity over SA Keys](./002-workload-identity-over-sa-keys.md)
