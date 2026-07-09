# GKE Cluster Recovery Runbook

**Target RTO:** 4 hours (SecondWave Business Continuity Requirement)
**Target RPO:** 1 hour (last available etcd snapshot)

## Scenario: Control Plane Failure

The GKE control plane is managed by Google — a full control plane failure is extremely rare. However, the following scenarios can cause cluster unavailability:

1. **CMEK key revocation/disablement**: If the KMS key used for etcd encryption is disabled or destroyed, the control plane cannot decrypt etcd and will not start.
2. **Network misconfiguration**: Deleting/modifying the VPC or subnet used by the private cluster.
3. **Quota exhaustion**: GKE API rate limiting or project-level compute quota exhaustion.
4. **Regional outage**: A GCP region-wide outage affecting the control plane.

## Recovery Steps

### Step 1: Assess the Situation

```bash
# Check if the cluster still exists
gcloud container clusters describe <CLUSTER_NAME> \
  --region <REGION> \
  --project <PROJECT_ID>

# Check control plane status
gcloud container clusters list \
  --project <PROJECT_ID> \
  --filter="name=<CLUSTER_NAME>"

# Check CMEK key status
gcloud kms keys describe <KEY_NAME> \
  --location <REGION> \
  --keyring <KEYRING> \
  --project <PROJECT_ID>
```

### Step 2: Verify KMS Key Status

If the CMEK key is disabled or destroyed:

```bash
# Check key state
gcloud kms keys list \
  --location <REGION> \
  --keyring <KEYRING> \
  --project <PROJECT_ID>

# Re-enable if disabled (takes effect within 60 seconds)
gcloud kms keys enable <KEY_NAME> \
  --location <REGION> \
  --keyring <KEYRING> \
  --project <PROJECT_ID>
```

**⚠️ SECURITY SAFEGUARD:** If the key is destroyed (scheduled destruction or immediate), the cluster is **permanently unrecoverable**. You must:
1. Restore from backup (if using Velero or similar)
2. Rebuild the cluster from Terraform
3. Restore workload state from the latest Velero backup

### Step 3: Verify VPC and Subnet

```bash
# Check VPC exists
gcloud compute networks describe <VPC_NAME> \
  --project <PROJECT_ID>

# Check subnet exists and has secondary ranges
gcloud compute networks subnets describe <SUBNET_NAME> \
  --region <REGION> \
  --project <PROJECT_ID>

# Verify secondary ranges for pods and services
gcloud compute networks subnets describe <SUBNET_NAME> \
  --region <REGION> \
  --project <PROJECT_ID> \
  --format="value(secondaryIpRanges)"
```

### Step 4: Rebuild Cluster from Terraform

If the cluster must be rebuilt:

```bash
# 1. Remove deletion_protection or set to false
terraform plan -out=tfplan
terraform apply tfplan

# 2. If that fails, import existing broken state
terraform import module.gke_cluster.google_container_cluster.primary \
  projects/<PROJECT>/locations/<REGION>/clusters/<CLUSTER_NAME>

# 3. Apply with deletion protection disabled
terraform plan -out=tfplan
terraform apply tfplan

# 4. Re-enable deletion protection
# Set deletion_protection = true and re-apply
```

### Step 5: Restore Workloads

After cluster recovery:

```bash
# 1. Restore Workload Identity bindings
# If using the iam-workload-identity module, re-apply Terraform

# 2. Restore Velero backups (if configured)
velero restore create --from-backup <LATEST_BACKUP>

# 3. Re-sync ArgoCD
argocd app sync <APP_NAME>
# or for Flux
flux reconcile kustomization <KUSTOMIZATION_NAME>
```

### Step 6: Validate Recovery

```bash
# Add to kubeconfig
gcloud container clusters get-credentials <CLUSTER_NAME> \
  --region <REGION> \
  --project <PROJECT_ID>

# Check node status
kubectl get nodes -o wide

# Check core DNS
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Check system pods
kubectl get pods -n kube-system
kubectl get pods -n cert-manager
kubectl get pods -n kyverno
kubectl get pods -n external-secrets

# Verify workload identity
kubectl run test-wi --image=google/cloud-sdk:latest \
  --rm -it --restart=Never \
  -- /bin/bash -c 'gcloud auth list'
```

## Prevention

1. **Never disable the CMEK key** without verifying no clusters depend on it.
2. **Never delete the VPC or subnet** used by the cluster (Terraform should prevent this).
3. **Monitor KMS key status** with Cloud Monitoring alerting.
4. **Enable Velero backups** for workload data, stored in a different region.
5. **Test recovery procedure quarterly** as part of SecondWave's BCP exercises.

## Related

- Terraform state: `secondwave-tfstate-<ENV>` GCS bucket
- Cluster config: `terraform.tfvars`
- Backups: Velero (configured in gitops-config repo)
