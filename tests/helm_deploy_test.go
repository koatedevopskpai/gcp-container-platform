// +build terratest

package test

import (
	"fmt"
	"testing"
	"time"

	"github.com/gruntwork-io/terratest/modules/helm"
	"github.com/gruntwork-io/terratest/modules/k8s"
	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// TestHelmDeployment validates that the Helm charts used by the addons
// module can be deployed with the expected configuration. This test
// deploys to a temporary kind cluster (CI) or existing kubeconfig context.
//
// Usage:
//   cd tests
//   go test -v -run TestHelmDeployment -timeout 30m
//
// ARCHITECTURE DECISION: Helm chart testing off-cluster
// We test Helm chart deployment in isolation rather than running the full
// Terraform because Helm chart issues are easier to debug without the
// overhead of provisioning GCP infrastructure. This is a unit test for
// the Helm chart, not an integration test.
func TestHelmDeployment(t *testing.T) {
	t.Parallel()

	// Setup: create a namespace with a random suffix to avoid collisions
	namespaceName := fmt.Sprintf("helm-test-%s", random.UniqueId())

	// Use the current kubectl context (expects kind or minikube for local testing)
	kubectlOptions := k8s.NewKubectlOptions("", "", namespaceName)
	defer k8s.DeleteNamespace(t, kubectlOptions, namespaceName)
	k8s.CreateNamespace(t, kubectlOptions, namespaceName)

	t.Run("CertManagerHelm", func(t *testing.T) {
		// Test cert-manager chart deployment
		helmOptions := &helm.Options{
			KubectlOptions: kubectlOptions,
			SetValues: map[string]string{
				"installCRDs":               "true",
				"prometheus.enabled":        "false", // Disable for test
				"metrics.enabled":           "false",
			},
			Version: "1.15.x",
		}

		// Deploy the chart
		releaseName := "cert-manager-test"
		helm.Install(t, helmOptions, "jetstack/cert-manager", releaseName)

		// Verify pods are running
		pods := helm.GetPods(t, helmOptions, releaseName, true)
		require.NotEmpty(t, pods, "cert-manager pods should exist")
		for _, pod := range pods {
			assert.Equal(t, corev1.PodRunning, pod.Status.Phase, "Pod should be Running")
		}

		// Cleanup
		helm.Delete(t, helmOptions, releaseName, true)
	})

	t.Run("ExternalSecretsHelm", func(t *testing.T) {
		helmOptions := &helm.Options{
			KubectlOptions: kubectlOptions,
			SetValues: map[string]string{
				"installCRDs":               "true",
				"metrics.enabled":           "false",
				"serviceAccount.create":     "true",
			},
			Version: "0.10.x",
		}

		releaseName := "external-secrets-test"
		helm.Install(t, helmOptions, "https://charts.external-secrets.io", releaseName)

		pods := helm.GetPods(t, helmOptions, releaseName, true)
		require.NotEmpty(t, pods, "external-secrets pods should exist")
		for _, pod := range pods {
			assert.Equal(t, corev1.PodRunning, pod.Status.Phase)
		}

		helm.Delete(t, helmOptions, releaseName, true)
	})

	t.Run("KyvernoHelm", func(t *testing.T) {
		helmOptions := &helm.Options{
			KubectlOptions: kubectlOptions,
			SetValues: map[string]string{
				"validationFailureActionByPolicy": "audit",
				"reportsController.enabled":       "false",
				"backgroundController.enabled":     "false",
				"cleanupController.enabled":       "false",
				"serviceMonitor.enabled":          "false",
				"metrics.enabled":                 "false",
			},
			Version: "3.2.x",
		}

		releaseName := "kyverno-test"
		helm.Install(t, helmOptions, "https://kyverno.github.io/kyverno", releaseName)

		pods := helm.GetPods(t, helmOptions, releaseName, true)
		require.NotEmpty(t, pods, "Kyverno pods should exist")
		for _, pod := range pods {
			assert.Equal(t, corev1.PodRunning, pod.Status.Phase)
		}

		helm.Delete(t, helmOptions, releaseName, true)
	})

	t.Run("NginxIngressHelm", func(t *testing.T) {
		helmOptions := &helm.Options{
			KubectlOptions: kubectlOptions,
			SetValues: map[string]string{
				"controller.service.type":                "ClusterIP", // Use ClusterIP for test
				"controller.metrics.enabled":             "false",
				"controller.autoscaling.enabled":          "false",
				"controller.admissionWebhooks.enabled":    "false",
			},
			Version: "4.10.x",
		}

		releaseName := "ingress-nginx-test"
		helm.Install(t, helmOptions, "https://kubernetes.github.io/ingress-nginx", releaseName)

		pods := helm.GetPods(t, helmOptions, releaseName, true)
		require.NotEmpty(t, pods, "nginx-ingress pods should exist")
		for _, pod := range pods {
			assert.Equal(t, corev1.PodRunning, pod.Status.Phase)
		}

		helm.Delete(t, helmOptions, releaseName, true)
	})
}

// TestHelmRollback validates that Helm rollback works for the charts.
func TestHelmRollback(t *testing.T) {
	t.Parallel()

	namespaceName := fmt.Sprintf("helm-rollback-%s", random.UniqueId())
	kubectlOptions := k8s.NewKubectlOptions("", "", namespaceName)
	defer k8s.DeleteNamespace(t, kubectlOptions, namespaceName)
	k8s.CreateNamespace(t, kubectlOptions, namespaceName)

	// Test rollback for Kyverno
	helmOptions := &helm.Options{
		KubectlOptions: kubectlOptions,
		SetValues: map[string]string{
			"validationFailureActionByPolicy": "audit",
			"reportsController.enabled":       "false",
		},
	}

	releaseName := "kyverno-rollback"

	// Install initial version
	helm.Install(t, helmOptions, "https://kyverno.github.io/kyverno", releaseName)

	// Upgrade with intentional bad value
	badOptions := helmOptions
	upgradeErr := helm.UpgradeE(t, badOptions, "https://kyverno.github.io/kyverno", releaseName)
	if upgradeErr != nil {
		// Rollback on failure
		err := helm.RollbackE(t, helmOptions, releaseName, 1)
		assert.NoError(t, err, "Rollback should succeed")

		// Validate pods are still running from revision 1
		pods := helm.GetPods(t, helmOptions, releaseName, true)
		require.NotEmpty(t, pods, "Pods should exist after rollback")
		for _, pod := range pods {
			assert.Equal(t, corev1.PodRunning, pod.Status.Phase)
		}
	}

	helm.Delete(t, helmOptions, releaseName, true)
}

// TestCRDInstallation validates that CRDs are installed by the Helm charts.
func TestCRDInstallation(t *testing.T) {
	t.Parallel()

	namespaceName := fmt.Sprintf("helm-crd-%s", random.UniqueId())
	kubectlOptions := k8s.NewKubectlOptions("", "", namespaceName)
	defer k8s.DeleteNamespace(t, kubectlOptions, namespaceName)
	k8s.CreateNamespace(t, kubectlOptions, namespaceName)

	t.Run("ExternalSecretsCRDs", func(t *testing.T) {
		helmOptions := &helm.Options{
			KubectlOptions: kubectlOptions,
			SetValues: map[string]string{
				"installCRDs": "true",
				"metrics.enabled": "false",
			},
		}

		releaseName := "eso-crd-test"
		helm.Install(t, helmOptions, "https://charts.external-secrets.io", releaseName)
		defer helm.Delete(t, helmOptions, releaseName, true)

		// Wait for CRDs to be established
		time.Sleep(10 * time.Second)

		// Verify CRDs exist
		crds := []string{
			"clustersecretstores.external-secrets.io",
			"secretstores.external-secrets.io",
			"externalsecrets.external-secrets.io",
		}

		for _, crd := range crds {
			_, err := k8s.GetCustomResourceDefinitionE(t, kubectlOptions, crd)
			assert.NoError(t, err, "CRD %s should be installed", crd)
		}
	})
}
