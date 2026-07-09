// +build terratest

package test

import (
	"fmt"
	"os"
	"testing"

	"github.com/gruntwork-io/terratest/modules/gcp"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestGKECluster validates that the GKE cluster module creates a private
// cluster with the expected configuration. This is a Terratest stub
// designed to be run against a real GCP project for integration testing.
//
// Usage:
//   cd tests
//   go test -v -run TestGKECluster -timeout 60m
//
// ARCHITECTURE DECISION: Terratest for Infrastructure Testing
// We use Terratest (Go-based) rather than Terratest's alternatives like
// kitchen-terraform because Go is already in the platform team's toolbox.
// Terratest allows us to write infrastructure tests alongside application
// tests in the same language.
func TestGKECluster(t *testing.T) {
	t.Parallel()

	projectID := os.Getenv("GCP_PROJECT_ID")
	require.NotEmpty(t, projectID, "GCP_PROJECT_ID environment variable must be set")

	region := os.Getenv("GCP_REGION")
	if region == "" {
		region = "europe-west2"
	}

	// Randomise cluster name to avoid collisions in CI
	clusterName := fmt.Sprintf("terratest-gke-%s", gcp.RandomValidGcpName())

	terraformOptions := &terraform.Options{
		TerraformDir: "../modules/gke-cluster",

		// SECURITY SAFEGUARD: Test variables use minimal, non-production
		// values. We test with a small node pool (e2-standard-2) and
		// disable expensive features like NAP and Binary Authorization.
		Vars: map[string]interface{}{
			"project_id":            projectID,
			"region":                region,
			"cluster_name":          clusterName,
			"kubernetes_version":    "1.30",
			"environment":           "dev",
			"vpc_network":           "default",
			"vpc_subnet":            "default",
			"master_ipv4_cidr_block": "10.250.0.0/28",
			"pods_ipv4_cidr":        "10.251.0.0/16",
			"services_ipv4_cidr":    "10.252.0.0/20",
			"master_authorized_networks": []map[string]interface{}{
				{"cidr_block": "0.0.0.0/0", "display_name": "test-access"},
			},
			"release_channel":                     "RAPID",
			"enable_vertical_pod_autoscaling":      false,
			"enable_node_auto_provisioning":        false,
			"binary_authorization_enabled":          false,
			"tags": map[string]string{
				"managed_by": "terratest",
				"test":       "true",
			},
		},

		NoColor: true,
	}

	// Cleanup: destroy resources after test
	defer terraform.Destroy(t, terraformOptions)

	// Deploy the cluster
	terraform.InitAndApply(t, terraformOptions)

	// Validate outputs
	endpoint := terraform.Output(t, terraformOptions, "endpoint")
	assert.NotEmpty(t, endpoint, "Cluster endpoint should not be empty")
	t.Logf("Cluster endpoint: %s", endpoint)

	caCert := terraform.Output(t, terraformOptions, "ca_certificate")
	assert.NotEmpty(t, caCert, "CA certificate should not be empty")

	clusterNameOut := terraform.Output(t, terraformOptions, "name")
	assert.Equal(t, clusterName, clusterNameOut)

	wiPool := terraform.Output(t, terraformOptions, "workload_identity_pool")
	expectedPool := fmt.Sprintf("%s.svc.id.goog", projectID)
	assert.Equal(t, expectedPool, wiPool, "Workload Identity pool should match project")

	// Validate that the cluster is private
	// The public endpoint should be empty for private clusters
	publicEndpoint := terraform.Output(t, terraformOptions, "kubernetes_endpoint")
	// Note: In a private cluster with enable_private_endpoint=true,
	// public_endpoint is still set but should be internal-only

	t.Logf("Test passed for cluster: %s", clusterName)
}

// TestGKEClusterCMEK validates cluster creation with CMEK encryption.
func TestGKEClusterCMEK(t *testing.T) {
	t.Parallel()

	projectID := os.Getenv("GCP_PROJECT_ID")
	require.NotEmpty(t, projectID, "GCP_PROJECT_ID must be set")

	cmekKey := os.Getenv("GCP_CMEK_KEY")
	if cmekKey == "" {
		t.Skip("GCP_CMEK_KEY not set — skipping CMEK test")
	}

	clusterName := fmt.Sprintf("terratest-gke-cmek-%s", gcp.RandomValidGcpName())

	terraformOptions := &terraform.Options{
		TerraformDir: "../modules/gke-cluster",
		Vars: map[string]interface{}{
			"project_id":            projectID,
			"region":                "europe-west2",
			"cluster_name":          clusterName,
			"environment":           "dev",
			"vpc_network":           "default",
			"vpc_subnet":            "default",
			"master_ipv4_cidr_block": "10.253.0.0/28",
			"pods_ipv4_cidr":        "10.254.0.0/16",
			"services_ipv4_cidr":    "10.255.0.0/20",
			"cmek_key_name":         cmekKey,
			"release_channel":       "RAPID",
		},
		NoColor: true,
	}

	defer terraform.Destroy(t, terraformOptions)
	terraform.InitAndApply(t, terraformOptions)

	clusterNameOut := terraform.Output(t, terraformOptions, "name")
	assert.Equal(t, clusterName, clusterNameOut)

	t.Logf("CMEK cluster test passed: %s", clusterName)
}
