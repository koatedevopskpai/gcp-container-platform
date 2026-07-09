#!/usr/bin/env bash
# ============================================================================
# Bootstrap Terraform Backend — GCS State Bucket + KMS Encryption
# ============================================================================
# ARCHITECTURE DECISION: Dedicated bootstrap script
# We don't manage state infrastructure with Terraform because Terraform
# needs a backend to store its state — bootstrap must be done manually
# or with a script. This script creates the GCS bucket and KMS key that
# Terraform will use for state storage.
#
# SECURITY SAFEGUARD: State bucket has object versioning enabled for
# state recovery and is encrypted with a CMEK key that the platform
# team controls. Public access is blocked with uniform bucket-level
# access.
#
# Usage:
#   ./scripts/bootstrap-backend.sh <project-id> <environment>
#
# Example:
#   ./scripts/bootstrap-backend.sh secondwave-platform-prod prod
# ============================================================================

set -euo pipefail

PROJECT_ID="${1:?Usage: $0 <project-id> <environment>}"
ENVIRONMENT="${2:?Usage: $0 <project-id> <environment>}"
REGION="europe-west2"

BUCKET_NAME="secondwave-tfstate-${ENVIRONMENT}"
KEYRING_NAME="tfstate"
KEY_NAME="tfstate-key"

echo "=== Bootstrap Terraform Backend ==="
echo "Project:    ${PROJECT_ID}"
echo "Environment: ${ENVIRONMENT}"
echo "Bucket:     ${BUCKET_NAME}"
echo "Region:     ${REGION}"
echo ""

# ARCHITECTURE DECISION: KMS key in the same region as the state bucket
# to minimise latency and cross-region data transfer costs. The key is
# in a dedicated key ring for state management, separate from GKE CMEK keys.
echo "1. Enabling required APIs..."
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  storage.googleapis.com \
  cloudkms.googleapis.com \
  --project="${PROJECT_ID}"

echo ""
echo "2. Creating KMS key ring and key..."
gcloud kms keyrings create "${KEYRING_NAME}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --quiet 2>/dev/null || echo "Key ring already exists"

gcloud kms keys create "${KEY_NAME}" \
  --location="${REGION}" \
  --keyring="${KEYRING_NAME}" \
  --purpose="encryption" \
  --project="${PROJECT_ID}" \
  --quiet 2>/dev/null || echo "Key already exists"

# Get the key resource name
KEY_RESOURCE_NAME=$(gcloud kms keys describe "${KEY_NAME}" \
  --location="${REGION}" \
  --keyring="${KEYRING_NAME}" \
  --project="${PROJECT_ID}" \
  --format="value(name)")

echo "  Key: ${KEY_RESOURCE_NAME}"

echo ""
echo "3. Creating GCS state bucket..."
gcloud storage buckets create "gs://${BUCKET_NAME}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --default-storage-class="STANDARD" \
  --uniform-bucket-level-access \
  --public-access-prevention \
  --soft-delete-duration="30d" \
  --quiet 2>/dev/null || echo "Bucket already exists"

echo ""
echo "4. Enabling object versioning on bucket..."
gcloud storage buckets update "gs://${BUCKET_NAME}" \
  --versioning \
  --project="${PROJECT_ID}" \
  --quiet

echo ""
echo "5. Setting CMEK encryption on bucket..."
gcloud storage buckets update "gs://${BUCKET_NAME}" \
  --encryption-key="${KEY_RESOURCE_NAME}" \
  --project="${PROJECT_ID}" \
  --quiet

echo ""
echo "6. Granting service account access to KMS key..."
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
TERRAFORM_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

# SECURITY SAFEGUARD: Only the Compute Engine SA and Cloud Build SA
# get access to the state KMS key. Individual engineers access state
# via Cloud Build or impersonation, never directly.
for SA in "${COMPUTE_SA}" "${TERRAFORM_SA}"; do
  gcloud kms keys add-iam-policy-binding "${KEY_NAME}" \
    --location="${REGION}" \
    --keyring="${KEYRING_NAME}" \
    --member="serviceAccount:${SA}" \
    --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || echo "Binding already exists for ${SA}"
done

echo ""
echo "7. Adding IAM for Terraform SA to access bucket..."
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
  --member="serviceAccount:${TERRAFORM_SA}" \
  --role="roles/storage.objectAdmin" \
  --project="${PROJECT_ID}" \
  --quiet 2>/dev/null || echo "IAM binding already exists"

echo ""
echo "=== Bootstrap Complete ==="
echo ""
echo "Add the following to your versions.tf backend block:"
echo ""
echo "terraform {"
echo "  backend \"gcs\" {"
echo "    bucket         = \"${BUCKET_NAME}\""
echo "    prefix         = \"gke-container-platform\""
echo "    encryption_key = \"${KEY_RESOURCE_NAME}\""
echo "  }"
echo "}"
echo ""
echo "KMS key resource name for CMEK in tfvars:"
echo "cmek_key_name = \"${KEY_RESOURCE_NAME}\""
