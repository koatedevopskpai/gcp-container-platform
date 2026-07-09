# ADR-003: Kyverno over OPA/Gatekeeper

## Status

Accepted

## Context

SecondWave's GKE cluster needs admission control to enforce pod security standards (no privileged containers, require probes, read-only root filesystem, etc.) The platform team has 2-3 people with varying Kubernetes expertise. The two main options in the Kubernetes ecosystem are:

1. **OPA/Gatekeeper**: The de facto standard for policy-as-code using Rego.
2. **Kyverno**: Kubernetes-native policies using YAML (no new language).

## Decision

We choose **Kyverno** for admission control.

## Rationale

### 1. Policy Language: YAML vs Rego

**Kyverno** uses Kubernetes-native YAML with JMESPath expressions:
```yaml
# Kyverno policy to disallow privileged containers
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged
spec:
  rules:
  - name: check-privileged
    match:
      any:
      - resources:
          kinds: ["Pod"]
    validate:
      message: "Privileged containers are not allowed"
      pattern:
        spec:
          containers:
          - securityContext:
              privileged: false
```

**OPA/Gatekeeper** requires Rego, a declarative query language:
```rego
package k8sdisallowprivileged

violation[{"msg": msg}] {
  container := input.review.object.spec.containers[_]
  container.securityContext.privileged
  msg := sprintf("Container %v is privileged", [container.name])
}
```

For a small platform team, Kyverno's YAML-based approach has a significantly lower learning curve. Team members can write policies on day one without studying Rego.

### 2. Built-in Features

Kyverno provides features out of the box that require additional tooling with Gatekeeper:
- **Policy generation**: Mutate-on-create to generate network policies, RBAC, etc.
- **Background scanning**: Audit existing resources against policies (no separate audit tool)
- **Policy reports**: Built-in reporting on policy compliance
- **Resource validation**: Built-in validation of custom resources

### 3. Ecosystem Integration

Kyverno is developed by Nirmata and has strong adoption in the CNCF ecosystem. Its policies are Kubernetes resources (ClusterPolicy, Policy) that integrate with GitOps workflows trivially.

### 4. Operational Overhead

| Aspect | Kyverno | OPA/Gatekeeper |
|---|---|---|
| Policy language | YAML + JMESPath | Rego (separate DSL) |
| CRD installation | 1 (ClusterPolicy) | 2 (ConstraintTemplate, Constraint) |
| Audit capability | Built-in | Requires OPA sidecar |
| Performance | Comparable | Comparable |
| Community policies | 150+ bundled | 50+ in gatekeeper-library |

## Consequences

1. **Vendor lock-in**: Kyverno is not a CNCF graduated project (as of writing — it's incubating). Migration to Gatekeeper would require rewriting all policies.
2. **Rego expertise**: The team will not gain Rego skills, which may matter if SecondWave adopts OPA for non-Kubernetes use cases (e.g., API authorization).
3. **Less extensibility**: For very complex policies (e.g., graph-based queries), Rego is more powerful than JMESPath.

## Alternatives Considered

- **OPA/Gatekeeper**: Rejected due to higher learning curve for the platform team.
- **Native Kubernetes Pod Security Standards (PSS)**: Adopted as a baseline (enforced by label), with Kyverno adding custom policies beyond PSS.
- **jsPolicy**: Smaller ecosystem and community. Rejected for maturity concerns.

## Related

- [ADR-001: GKE Standard over Autopilot](./001-gke-standard-over-autopilot.md)
