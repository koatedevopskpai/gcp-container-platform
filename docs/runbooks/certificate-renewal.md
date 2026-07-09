# Certificate Renewal Troubleshooting

## cert-manager Overview

cert-manager manages TLS certificates for all SecondWave ingress endpoints. Certificates are issued by Let's Encrypt (production) via the `letsencrypt-prod` ClusterIssuer using DNS-01 validation through Google Cloud DNS.

## Symptoms

| Symptom | Likely Cause |
|---|---|
| Browser shows "NET::ERR_CERT_DATE_INVALID" | Certificate not renewed |
| Ingress returns 503 | Certificate in `Failed` state |
| `kubectl get certificates` shows `Ready=False` | DNS-01 challenge failed |
| ArgoCD sync warning about certificate | External DNS pointing to wrong target |

## Diagnostic Steps

### 1. Check Certificate Status

```bash
# List all certificates
kubectl get certificates --all-namespaces

# Describe a specific certificate
kubectl describe certificate <NAME> -n <NAMESPACE>

# Check events
kubectl get events --all-namespaces \
  --field-selector involvedObject.kind=Certificate
```

### 2. Check cert-manager Pod Logs

```bash
# Get controller logs
kubectl logs -n cert-manager \
  -l app.kubernetes.io/name=cert-manager \
  --tail=100

# Check for DNS-01 challenge errors
# Look for: "Failed to determine zone", "No matching Zone", "Challenge failed"
```

### 3. Verify DNS Configuration

```bash
# Check the DNS record exists
gcloud dns record-sets list \
  --zone=<MANAGED_ZONE> \
  --name="_acme-challenge.<DOMAIN>." \
  --project=<PROJECT_ID>

# Verify the record matches the pending challenge
# Check cert-manager logs for the expected TXT record value
```

### 4. Check ClusterIssuer Status

```bash
kubectl describe clusterissuer letsencrypt-prod

# Should show:
#   Status:
#     Conditions:
#       Last Transition Time: ...
#       Message:               The ACME account was registered with the ACME server
#       Reason:                ACMEAccountRegistered
#       Status:                True
#       Type:                  Ready
```

### 5. Verify Workload Identity

```bash
# Check cert-manager SA annotation
kubectl describe sa cert-manager -n cert-manager
# Expected annotation: iam.gke.io/gcp-service-account: cert-manager-sa@...

# Test impersonation
kubectl run cert-manager-test --image=google/cloud-sdk:latest -n cert-manager \
  --rm -it --restart=Never -- \
  gcloud auth list
```

## Common Issues and Resolutions

### Issue 1: DNS-01 Challenge Fails

**Cause**: cert-manager cannot create/delete DNS records in Google Cloud DNS.

**Resolution**:
1. Verify the Workload Identity binding for `cert-manager-sa` is correct.
2. Check that the GSA `cert-manager-sa` has `roles/dns.admin` on the managed zone.
3. Ensure the managed zone name in the ClusterIssuer matches the actual zone.

### Issue 2: Let's Encrypt Rate Limiting

**Cause**: More than 50 certificates per domain per week.

**Resolution**:
1. Check if non-production certificates use the `letsencrypt-staging` issuer (higher limits).
2. Consolidate SANs into a single certificate where possible.
3. Wait for the rate limit window to reset (168h from first failure).

### Issue 3: Certificate Not Auto-Renewing

**Cause**: cert-manager renewal time is 30 days before expiry; if not ready, check:

1. Pod resource constraints (check pod metrics)
2. cert-manager API rate limiting with Let's Encrypt
3. Network connectivity to Let's Encrypt servers (acme-v02.api.letsencrypt.org)

### Issue 4: Ingress Controller Not Picking Up Certificate

**Cause**: Secret not projected to the correct namespace or ingress annotation missing.

**Resolution**:
```bash
# Verify TLS secret exists in the same namespace as the ingress
kubectl get secret <TLS_SECRET_NAME> -n <INGRESS_NAMESPACE>

# Check ingress TLS section
kubectl describe ingress <INGRESS_NAME> -n <INGRESS_NAMESPACE>
```

## Fix Commands

```bash
# Force certificate renewal (delete and recreate)
kubectl delete certificate <NAME> -n <NAMESPACE>
# cert-manager will recreate it automatically

# Force a single certificate to re-issue
kubectl annotate certificate <NAME> -n <NAMESPACE> \
  cert-manager.io/issue-temporary-certificate="true" \
  --overwrite

# Restart cert-manager if hung
kubectl rollout restart -n cert-manager deployment/cert-manager
kubectl rollout restart -n cert-manager deployment/cert-manager-webhook
```

## Monitoring Alerts

The following alerts are configured in Cloud Monitoring:

- **CertificateExpiringSoon**: Fires when a certificate will expire in <14 days
- **CertificateFailed**: Fires when a Certificate enters `Ready=False` state
- **DNS01ChallengeFailure**: Fires when DNS-01 challenge retries exceed 3

## Preventative Measures

1. **Monitor certificate expiry**: Use cert-manager's built-in metrics (`certmanager_certificate_expiry_timestamp_seconds`).
2. **Alert on failures**: Configure PrometheusAlertManager or Cloud Monitoring to alert on certificate issues.
3. **Test staging issuer first**: Use `letsencrypt-staging` for non-production environments to avoid rate limits.
4. **Backup cert-manager resources**: Include Certificate and Issuer resources in Velero backups.

## Related

- [ADR-002: Workload Identity over SA Keys](../ADR/002-workload-identity-over-sa-keys.md)
