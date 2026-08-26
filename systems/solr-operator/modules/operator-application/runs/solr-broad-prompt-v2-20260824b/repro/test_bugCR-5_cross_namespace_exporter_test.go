package cr5repro

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	solrv1beta1 "github.com/apache/solr-operator/api/v1beta1"
	"github.com/apache/solr-operator/controllers"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
)

var repoRoot = os.Getenv("SOURCE_REPO")

const (
	cloudNamespace    = "cr5-cloud"
	exporterNamespace = "cr5-exporter"
	cloudName         = "shared-solr"
	crossExporter     = "cross-namespace"
	controlExporter   = "same-namespace-control"
	oldImage          = "example.invalid/solr:old"
	newImage          = "example.invalid/solr:new"
	oldZK             = "old-zk.cr5-cloud.svc:2181/old"
	newZK             = "new-zk.cr5-cloud.svc:2181/new"
)

// TestCR5CrossNamespaceExporterStaysStale uses a real envtest API server and
// the production controller registration. All trigger operations are normal
// Kubernetes API creates/updates; there is no direct reconciler call, state
// injection, failpoint, sleep inside production code, or source patch.
func TestCR5CrossNamespaceExporterStaysStale(t *testing.T) {
	if repoRoot == "" {
		t.Fatal("SOURCE_REPO must point to the solr-operator checkout")
	}
	scheme := runtime.NewScheme()
	must(t, clientgoscheme.AddToScheme(scheme), "register Kubernetes APIs")
	must(t, solrv1beta1.AddToScheme(scheme), "register Solr APIs")

	testEnv := &envtest.Environment{
		CRDDirectoryPaths:     []string{filepath.Join(repoRoot, "config", "crd", "bases")},
		ErrorIfCRDPathMissing: true,
	}
	cfg, err := testEnv.Start()
	must(t, err, "start envtest control plane")

	managerCtx, cancelManager := context.WithCancel(context.Background())
	managerDone := make(chan error, 1)
	defer func() {
		cancelManager()
		select {
		case managerErr := <-managerDone:
			if managerErr != nil {
				t.Logf("manager stopped with: %v", managerErr)
			}
		case <-time.After(5 * time.Second):
			t.Log("manager did not stop within 5s")
		}
		must(t, testEnv.Stop(), "stop envtest control plane")
	}()

	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: "0"},
		HealthProbeBindAddress: "0",
	})
	must(t, err, "create controller manager")
	must(t, (&controllers.SolrPrometheusExporterReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr), "register production exporter controller")

	go func() {
		managerDone <- mgr.Start(managerCtx)
	}()
	if !mgr.GetCache().WaitForCacheSync(managerCtx) {
		t.Fatal("controller cache did not sync")
	}

	apiClient, err := client.New(cfg, client.Options{Scheme: scheme})
	must(t, err, "create public Kubernetes API client")
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	for _, namespace := range []string{cloudNamespace, exporterNamespace} {
		must(t, apiClient.Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: namespace}}), "create namespace "+namespace)
	}

	cloud := &solrv1beta1.SolrCloud{
		ObjectMeta: metav1.ObjectMeta{Name: cloudName, Namespace: cloudNamespace},
		Spec: solrv1beta1.SolrCloudSpec{
			SolrImage: image("old"),
		},
	}
	must(t, apiClient.Create(ctx, cloud), "create referenced SolrCloud")
	setCloudStatus(t, ctx, apiClient, oldZKHost(), "/old")

	createExporter(t, ctx, apiClient, crossExporter, exporterNamespace, cloudNamespace)
	createExporter(t, ctx, apiClient, controlExporter, cloudNamespace, cloudNamespace)

	waitDeploymentState(t, ctx, apiClient, exporterNamespace, crossExporter, oldImage, oldZK)
	waitDeploymentState(t, ctx, apiClient, cloudNamespace, controlExporter, oldImage, oldZK)
	markDeploymentReady(t, ctx, apiClient, exporterNamespace, crossExporter)
	waitExporterReady(t, ctx, apiClient, exporterNamespace, crossExporter, true)
	t.Logf("INITIAL cross deployment image=%s zk=%s exporterReady=true", oldImage, oldZK)

	// Normal supported CR transition: change both values that the exporter
	// derives from its referenced SolrCloud.
	currentCloud := &solrv1beta1.SolrCloud{}
	must(t, apiClient.Get(ctx, client.ObjectKey{Name: cloudName, Namespace: cloudNamespace}, currentCloud), "get SolrCloud before image update")
	currentCloud.Spec.SolrImage = image("new")
	must(t, apiClient.Update(ctx, currentCloud), "update SolrCloud image")

	// Isolate the ordinary user-controlled spec transition before changing any
	// controller-owned status. The same-namespace control must consume this
	// event, while the cross-namespace Deployment must remain on the old image.
	waitDeploymentState(t, ctx, apiClient, cloudNamespace, controlExporter, newImage, oldZK)
	assertDeploymentStateConsistently(t, ctx, apiClient, exporterNamespace, crossExporter, oldImage, oldZK, time.Second)
	waitExporterReady(t, ctx, apiClient, exporterNamespace, crossExporter, true)
	t.Logf("PUBLIC-TRIGGER image-only update: control image=%s cross image=%s cross exporterReady=true", newImage, oldImage)

	setCloudStatus(t, ctx, apiClient, newZKHost(), "/new")
	t.Log("TRIGGER updated referenced SolrCloud image and ZooKeeper identity through Kubernetes API")

	// Positive control: the same cloud event updates an exporter in the cloud's
	// own namespace, proving the manager watch and reconcile path are active.
	waitDeploymentState(t, ctx, apiClient, cloudNamespace, controlExporter, newImage, newZK)
	t.Logf("CONTROL same-namespace deployment converged image=%s zk=%s", newImage, newZK)

	// The cross-namespace exporter receives no enqueue. Verify the bad state is
	// stable rather than a transient snapshot, and that its public status remains
	// Ready even though its Deployment still carries the old target identity.
	assertDeploymentStateConsistently(t, ctx, apiClient, exporterNamespace, crossExporter, oldImage, oldZK, 3*time.Second)
	waitExporterReady(t, ctx, apiClient, exporterNamespace, crossExporter, true)
	t.Logf("BUG cross-namespace deployment remained image=%s zk=%s while exporter status.ready=true", oldImage, oldZK)
	kubectlGetExporter(t, ctx, cfg, crossExporter, exporterNamespace)

	// A new event on the exporter itself repairs the stale Deployment. This is a
	// recovery control, not an automatic downstream safeguard: without this new
	// API operation, the stale state above remained stable.
	currentExporter := &solrv1beta1.SolrPrometheusExporter{}
	must(t, apiClient.Get(ctx, client.ObjectKey{Name: crossExporter, Namespace: exporterNamespace}, currentExporter), "get cross-namespace exporter")
	if currentExporter.Annotations == nil {
		currentExporter.Annotations = map[string]string{}
	}
	currentExporter.Annotations["cr5-repro/reconcile"] = "requested"
	must(t, apiClient.Update(ctx, currentExporter), "send explicit exporter reconcile event")
	waitDeploymentState(t, ctx, apiClient, exporterNamespace, crossExporter, newImage, newZK)
	t.Logf("RECOVERY explicit exporter event converged image=%s zk=%s", newImage, newZK)
}

func kubectlGetExporter(t *testing.T, ctx context.Context, cfg *rest.Config, name, namespace string) {
	t.Helper()
	kubeconfig := clientcmdapi.Config{
		Clusters: map[string]*clientcmdapi.Cluster{
			"envtest": {
				Server:                   cfg.Host,
				CertificateAuthorityData: cfg.CAData,
				InsecureSkipTLSVerify:    cfg.Insecure,
			},
		},
		AuthInfos: map[string]*clientcmdapi.AuthInfo{
			"envtest": {
				ClientCertificateData: cfg.CertData,
				ClientKeyData:         cfg.KeyData,
				Token:                 cfg.BearerToken,
			},
		},
		Contexts: map[string]*clientcmdapi.Context{
			"envtest": {Cluster: "envtest", AuthInfo: "envtest", Namespace: namespace},
		},
		CurrentContext: "envtest",
	}
	kubeconfigPath := filepath.Join(t.TempDir(), "kubeconfig")
	must(t, clientcmd.WriteToFile(kubeconfig, kubeconfigPath), "write temporary envtest kubeconfig")
	kubectlPath := filepath.Join(os.Getenv("KUBEBUILDER_ASSETS"), "kubectl")
	output, err := exec.CommandContext(ctx, kubectlPath, "--kubeconfig", kubeconfigPath, "get", "solrmetrics", name, "-n", namespace).CombinedOutput()
	must(t, err, "read exporter through kubectl")
	consumerOutput := strings.TrimSpace(string(output))
	if !strings.Contains(consumerOutput, "true") {
		t.Fatalf("kubectl did not observe Ready=true:\n%s", consumerOutput)
	}
	t.Logf("CONSUMER kubectl observed public Ready column:\n%s", consumerOutput)
}

func image(tag string) *solrv1beta1.ContainerImage {
	return &solrv1beta1.ContainerImage{
		Repository: "example.invalid/solr",
		Tag:        tag,
		PullPolicy: corev1.PullIfNotPresent,
	}
}

func oldZKHost() string { return "old-zk.cr5-cloud.svc:2181" }
func newZKHost() string { return "new-zk.cr5-cloud.svc:2181" }

func setCloudStatus(t *testing.T, ctx context.Context, c client.Client, host, chroot string) {
	t.Helper()
	cloud := &solrv1beta1.SolrCloud{}
	must(t, c.Get(ctx, client.ObjectKey{Name: cloudName, Namespace: cloudNamespace}, cloud), "get SolrCloud before status update")
	cloud.Status.SolrNodes = []solrv1beta1.SolrNodeStatus{}
	cloud.Status.ZookeeperConnectionInfo = solrv1beta1.ZookeeperConnectionInfo{
		InternalConnectionString: host,
		ChRoot:                   chroot,
	}
	must(t, c.Status().Update(ctx, cloud), "update SolrCloud ZooKeeper status")
}

func createExporter(t *testing.T, ctx context.Context, c client.Client, name, namespace, referencedNamespace string) {
	t.Helper()
	exporter := &solrv1beta1.SolrPrometheusExporter{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace},
		Spec: solrv1beta1.SolrPrometheusExporterSpec{
			SolrReference: solrv1beta1.SolrReference{
				Cloud: &solrv1beta1.SolrCloudReference{Name: cloudName, Namespace: referencedNamespace},
			},
			NumThreads: 1,
		},
	}
	must(t, c.Create(ctx, exporter), "create exporter "+namespace+"/"+name)
}

func markDeploymentReady(t *testing.T, ctx context.Context, c client.Client, namespace, exporterName string) {
	t.Helper()
	deployment := getDeployment(t, ctx, c, namespace, exporterName)
	deployment.Status.Replicas = 1
	deployment.Status.ReadyReplicas = 1
	deployment.Status.AvailableReplicas = 1
	must(t, c.Status().Update(ctx, deployment), "mark exporter Deployment ready")
}

func waitExporterReady(t *testing.T, ctx context.Context, c client.Client, namespace, name string, expected bool) {
	t.Helper()
	eventually(t, ctx, "exporter status.ready", func() (bool, string, error) {
		exporter := &solrv1beta1.SolrPrometheusExporter{}
		if err := c.Get(ctx, client.ObjectKey{Name: name, Namespace: namespace}, exporter); err != nil {
			return false, "", err
		}
		return exporter.Status.Ready == expected, fmt.Sprintf("ready=%t", exporter.Status.Ready), nil
	})
}

func waitDeploymentState(t *testing.T, ctx context.Context, c client.Client, namespace, exporterName, expectedImage, expectedZK string) {
	t.Helper()
	eventually(t, ctx, "Deployment state", func() (bool, string, error) {
		deployment := &appsv1.Deployment{}
		err := c.Get(ctx, client.ObjectKey{Name: exporterName + "-solr-metrics", Namespace: namespace}, deployment)
		if err != nil {
			return false, "", err
		}
		actualImage, actualZK := deploymentState(deployment)
		return actualImage == expectedImage && actualZK == expectedZK,
			fmt.Sprintf("image=%s zk=%s", actualImage, actualZK), nil
	})
}

func assertDeploymentStateConsistently(t *testing.T, ctx context.Context, c client.Client, namespace, exporterName, expectedImage, expectedZK string, duration time.Duration) {
	t.Helper()
	deadline := time.Now().Add(duration)
	for time.Now().Before(deadline) {
		deployment := getDeployment(t, ctx, c, namespace, exporterName)
		actualImage, actualZK := deploymentState(deployment)
		if actualImage != expectedImage || actualZK != expectedZK {
			t.Fatalf("cross-namespace Deployment unexpectedly changed during stability window: image=%s zk=%s", actualImage, actualZK)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func getDeployment(t *testing.T, ctx context.Context, c client.Client, namespace, exporterName string) *appsv1.Deployment {
	t.Helper()
	var deployment *appsv1.Deployment
	eventually(t, ctx, "Deployment existence", func() (bool, string, error) {
		deployment = &appsv1.Deployment{}
		err := c.Get(ctx, client.ObjectKey{Name: exporterName + "-solr-metrics", Namespace: namespace}, deployment)
		return err == nil, "", err
	})
	return deployment
}

func deploymentState(deployment *appsv1.Deployment) (imageName, zkHost string) {
	if len(deployment.Spec.Template.Spec.Containers) == 0 {
		return "", ""
	}
	container := deployment.Spec.Template.Spec.Containers[0]
	for _, env := range container.Env {
		if env.Name == "ZK_HOST" {
			zkHost = env.Value
			break
		}
	}
	return container.Image, zkHost
}

func eventually(t *testing.T, ctx context.Context, description string, condition func() (bool, string, error)) {
	t.Helper()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	var last string
	var lastErr error
	for {
		ok, state, err := condition()
		if ok {
			return
		}
		last, lastErr = state, err
		select {
		case <-ctx.Done():
			t.Fatalf("timed out waiting for %s: last state=%q last error=%v", description, last, lastErr)
		case <-ticker.C:
		}
	}
}

func must(t *testing.T, err error, action string) {
	t.Helper()
	if err != nil {
		t.Fatalf("%s: %v", action, err)
	}
}
