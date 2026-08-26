#!/usr/bin/env bash
set -euo pipefail

SOURCE_REPO="${SOURCE_REPO:-${1:-}}"
if [[ -z "$SOURCE_REPO" ]]; then
  echo "usage: SOURCE_REPO=/path/to/solr-operator $0" >&2
  exit 2
fi

GO_BIN="${GO_BIN:-$(command -v go || true)}"
if [[ -z "$GO_BIN" && -x /usr/local/go/bin/go ]]; then
  GO_BIN=/usr/local/go/bin/go
fi
repro_tmp_dir="$(mktemp -d)"
WORKTREE="$repro_tmp_dir/repo"
cp -a "$SOURCE_REPO/." "$WORKTREE"
TEST_FILE="$WORKTREE/controllers/bugmc5_confirm_test.go"

if [[ ! -x "$GO_BIN" ]]; then
  echo "GO_BIN is not executable: $GO_BIN"
  exit 2
fi

cleanup() {
  rm -rf "$repro_tmp_dir"
}
trap cleanup EXIT

cat > "$TEST_FILE" <<'GOEOF'
package controllers

import (
	"context"
	stderrors "errors"
	"fmt"
	"strings"
	"testing"

	solrv1beta1 "github.com/apache/solr-operator/api/v1beta1"
	"github.com/apache/solr-operator/controllers/util"
	"github.com/go-logr/logr"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

func TestBugMC5FailedBootstrapSecretCreateLeavesReadyCloudWithoutSecurityBootstrap(t *testing.T) {
	ctx := context.Background()
	sc := bugMC5SolrCloud()
	status := &solrv1beta1.SolrCloudStatus{ZookeeperConnectionInfo: *sc.Spec.ZookeeperRef.ConnectionInfo}
	reconcileConfigInfo := map[string]string{
		util.SolrXmlFile:          sc.ConfigMapName(),
		util.SolrXmlMd5Annotation: "bugmc5-solrxml",
	}

	level0Client := bugMC5Client(t)
	level0Security, err := util.ReconcileSecurityConfig(ctx, &level0Client, sc.DeepCopy())
	if err != nil {
		t.Fatalf("Level 0 control reconcile failed: %v", err)
	}
	var level0Bootstrap corev1.Secret
	if err := level0Client.Get(ctx, types.NamespacedName{Name: sc.SecurityBootstrapSecretName(), Namespace: sc.Namespace}, &level0Bootstrap); err != nil {
		t.Fatalf("Level 0 control did not create bootstrap Secret: %v", err)
	}
	level0StatefulSet := util.GenerateStatefulSet(sc.DeepCopy(), status, nil, reconcileConfigInfo, nil, level0Security)
	if !bugMC5TemplateHasSecurityUpload(level0StatefulSet) {
		t.Fatalf("Level 0 control should include SECURITY_JSON upload when both generated Secrets are created")
	}
	fmt.Println("LEVEL0_CONTROL: normal generated BasicAuth creates bootstrap Secret and setup-zk SECURITY_JSON")

	var failedSecondCreate bool
	level2Client := bugMC5ClientWithBootstrapCreateFailure(t, &failedSecondCreate, sc.SecurityBootstrapSecretName())
	_, err = util.ReconcileSecurityConfig(ctx, &level2Client, sc.DeepCopy())
	if err == nil {
		t.Fatalf("Level 2 setup expected injected bootstrap Secret create failure")
	}
	if !failedSecondCreate {
		t.Fatalf("Level 2 setup did not hit the injected bootstrap Secret create failure")
	}
	var authSecret corev1.Secret
	if err := level2Client.Get(ctx, types.NamespacedName{Name: sc.BasicAuthSecretName(), Namespace: sc.Namespace}, &authSecret); err != nil {
		t.Fatalf("Level 2 setup did not persist first credentials Secret: %v", err)
	}
	var missingBootstrap corev1.Secret
	err = level2Client.Get(ctx, types.NamespacedName{Name: sc.SecurityBootstrapSecretName(), Namespace: sc.Namespace}, &missingBootstrap)
	if !apierrors.IsNotFound(err) {
		t.Fatalf("Level 2 setup expected missing bootstrap Secret after failed second create, got: %v", err)
	}
	fmt.Println("LEVEL2_SETUP: first credentials Secret persisted; second bootstrap Secret create failed; bootstrap Secret absent")

	level2Security, err := util.ReconcileSecurityConfig(ctx, &level2Client, sc.DeepCopy())
	if err != nil {
		t.Fatalf("Level 2 retry reconcile should tolerate missing bootstrap Secret once credentials Secret exists, got: %v", err)
	}
	if level2Security.CredentialsSecret == nil {
		t.Fatalf("Level 2 retry did not return credentials Secret")
	}
	if level2Security.SecurityJson != "" || level2Security.SecurityJsonSrc != nil {
		t.Fatalf("Level 2 retry unexpectedly recovered bootstrap security.json: %q %v", level2Security.SecurityJson, level2Security.SecurityJsonSrc)
	}
	level2StatefulSet := util.GenerateStatefulSet(sc.DeepCopy(), status, nil, reconcileConfigInfo, nil, level2Security)
	if bugMC5TemplateHasSecurityUpload(level2StatefulSet) {
		t.Fatalf("Level 2 retry generated a pod template with SECURITY_JSON despite missing bootstrap Secret")
	}
	fmt.Println("LEVEL2_TEMPLATE: retry generated StatefulSet without SECURITY_JSON security upload")

	readyPod := corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      sc.GetSolrPodName(0),
			Namespace: sc.Namespace,
			Labels:    level2StatefulSet.Spec.Selector.MatchLabels,
		},
		Spec: level2StatefulSet.Spec.Template.Spec,
		Status: corev1.PodStatus{
			Conditions: []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionTrue}},
			ContainerStatuses: []corev1.ContainerStatus{{
				Name:  util.SolrNodeContainer,
				Image: sc.Spec.SolrImage.ToImageName(),
			}},
		},
	}
	ssStatus := appsv1.StatefulSetStatus{
		Replicas:        1,
		ReadyReplicas:   1,
		UpdatedReplicas: 1,
	}
	observedStatus := &solrv1beta1.SolrCloudStatus{}
	podSelector, err := metav1.LabelSelectorAsSelector(level2StatefulSet.Spec.Selector)
	if err != nil {
		t.Fatalf("generated StatefulSet selector is invalid: %v", err)
	}
	_, availableUpdated, shouldRequeue, err := createCloudStatus(sc.DeepCopy(), observedStatus, ssStatus, podSelector, []corev1.Pod{readyPod})
	if err != nil {
		t.Fatalf("createCloudStatus returned error: %v", err)
	}
	if observedStatus.ReadyReplicas != 1 || availableUpdated != 1 || shouldRequeue {
		t.Fatalf("expected status to accept Kubernetes PodReady as ready; ReadyReplicas=%d availableUpdated=%d shouldRequeue=%v", observedStatus.ReadyReplicas, availableUpdated, shouldRequeue)
	}
	fmt.Printf("LEVEL2_STATUS: createCloudStatus reported ReadyReplicas=%d from PodReady with no SECURITY_JSON upload\n", observedStatus.ReadyReplicas)
	fmt.Println("BUG_TRIGGERED: Ready SolrCloud status can be produced while generated BasicAuth bootstrap security.json was never installed")
}

func bugMC5SolrCloud() *solrv1beta1.SolrCloud {
	replicas := int32(1)
	sc := &solrv1beta1.SolrCloud{
		TypeMeta: metav1.TypeMeta{
			APIVersion: "solr.apache.org/v1beta1",
			Kind:       "SolrCloud",
		},
		ObjectMeta: metav1.ObjectMeta{
			Name:      "bugmc5",
			Namespace: "default",
			UID:       types.UID("bugmc5-uid"),
		},
		Spec: solrv1beta1.SolrCloudSpec{
			Replicas: &replicas,
			ZookeeperRef: &solrv1beta1.ZookeeperRef{
				ConnectionInfo: &solrv1beta1.ZookeeperConnectionInfo{
					InternalConnectionString: "zk:2181",
					ChRoot:                   "/",
				},
			},
			SolrSecurity: &solrv1beta1.SolrSecurityOptions{
				AuthenticationType: solrv1beta1.Basic,
			},
		},
	}
	sc.WithDefaults(logr.Discard())
	return sc
}

func bugMC5Client(t *testing.T) client.Client {
	t.Helper()
	testScheme := runtime.NewScheme()
	if err := scheme.AddToScheme(testScheme); err != nil {
		t.Fatalf("add client-go scheme: %v", err)
	}
	if err := solrv1beta1.AddToScheme(testScheme); err != nil {
		t.Fatalf("add solr scheme: %v", err)
	}
	return fake.NewClientBuilder().WithScheme(testScheme).Build()
}

func bugMC5ClientWithBootstrapCreateFailure(t *testing.T, failed *bool, bootstrapName string) client.Client {
	t.Helper()
	testScheme := runtime.NewScheme()
	if err := scheme.AddToScheme(testScheme); err != nil {
		t.Fatalf("add client-go scheme: %v", err)
	}
	if err := solrv1beta1.AddToScheme(testScheme); err != nil {
		t.Fatalf("add solr scheme: %v", err)
	}
	return fake.NewClientBuilder().WithScheme(testScheme).WithInterceptorFuncs(interceptor.Funcs{
		Create: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.CreateOption) error {
			if secret, ok := obj.(*corev1.Secret); ok && secret.Name == bootstrapName {
				*failed = true
				return apierrors.NewInternalError(stderrors.New("injected failure for MC-5 bootstrap Secret create"))
			}
			return c.Create(ctx, obj, opts...)
		},
	}).Build()
}

func bugMC5TemplateHasSecurityUpload(sts *appsv1.StatefulSet) bool {
	for _, container := range sts.Spec.Template.Spec.InitContainers {
		for _, env := range container.Env {
			if env.Name == "SECURITY_JSON" {
				return true
			}
		}
		if len(container.Command) >= 3 && strings.Contains(container.Command[2], "SECURITY_JSON") {
			return true
		}
	}
	return false
}
GOEOF

cd "$WORKTREE"
timeout 10m "$GO_BIN" test ./controllers -run TestBugMC5FailedBootstrapSecretCreateLeavesReadyCloudWithoutSecurityBootstrap -count=1 -v
