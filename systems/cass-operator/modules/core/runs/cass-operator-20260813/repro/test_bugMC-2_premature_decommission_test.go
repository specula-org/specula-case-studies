// Copyright DataStax, Inc.
// Please see the included license file for details.

// Reproduction for finding MC-2:
//   "Premature decommission completion -> PVC deletion before the node left the ring"
//
// MC counterexample: spec/output/MC_hunt_scenario2_dataloss.out
// Invariant violated: NoDataLossOnDecommission
//
// Mechanism: a transient mgmt /api/v0/metadata/endpoints error (or no ready pod)
// makes getCassMetadataEndpoints() return EMPTY ring metadata. With empty epData,
// IsDoneDecommissioning() skips both the PodIP and HostID loops and falls through to
// `// Gone from the ring completely? return true` (decommission_node.go:291-292),
// declaring the node decommissioned even though the real ring still shows it NORMAL.
// CheckDecommissioningNodes then runs cleanUpAfterDecommissionedPod ->
// DeletePodPvcs, deleting the node's PVC before it authoritatively LEFT -> data loss.
//
// HOW TO RUN: place this file in pkg/reconciliation/ and run
//   go test ./pkg/reconciliation/ -run TestMC2 -count=1 -v
//
// This is a Level 1 reproduction: the real reconcile helpers are driven end-to-end;
// the only injected condition is a genuine failure mode (mgmt API returns HTTP 500 on
// the metadata endpoint), which the operator explicitly handles and the fault model
// injects as GetCassMetadataEndpointsError (MC state 2). No system logic is altered.

package reconciliation

import (
	"io"
	"net/http"
	"testing"

	"github.com/go-logr/logr"
	api "github.com/k8ssandra/cass-operator/apis/cassandra/v1beta1"
	"github.com/k8ssandra/cass-operator/pkg/httphelper"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

// Test 1 (unit, with negative control): the core wrong decision.
// Empty metadata -> IsDoneDecommissioning reports "done" even though the node is
// still NORMAL in the ring. Control: with observed NORMAL metadata it correctly
// reports "not done".
func TestMC2_IsDoneDecommissioning_EmptyMetadataFalsePositive(t *testing.T) {
	logger := logr.Discard()

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "pod-1"},
		Status:     corev1.PodStatus{PodIP: "10.0.0.5"},
	}
	// The operator knows this pod's HostID (populated during normal operation).
	nodeStatuses := api.CassandraStatusMap{
		"pod-1": api.CassandraNodeStatus{HostID: "host-1"},
	}

	// BUG: transient mgmt error => empty endpoint metadata.
	empty := httphelper.CassMetadataEndpoints{}
	if !IsDoneDecommissioning(pod, empty, nodeStatuses, logger) {
		t.Fatalf("expected the buggy fall-through (true) with empty metadata")
	}
	t.Logf("BUG: IsDoneDecommissioning(empty metadata) = true (falls through decommission_node.go:291-292)")

	// CONTROL: real ring still shows the node NORMAL (not LEFT) -> must be false.
	normal := httphelper.CassMetadataEndpoints{Entity: []httphelper.EndpointState{
		{HostID: "host-1", RpcAddress: "10.0.0.5", Status: "NORMAL"},
	}}
	if IsDoneDecommissioning(pod, normal, nodeStatuses, logger) {
		t.Fatalf("control failed: node is NORMAL, IsDoneDecommissioning must be false")
	}
	t.Logf("CONTROL: IsDoneDecommissioning(NORMAL in ring) = false (correct)")
	t.Logf("=> The empty-metadata path yields a FALSE-POSITIVE completion.")
}

func newDecommissioningPodWithPVC(namespace, pvcName string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "pod-1",
			Namespace: namespace,
			Labels:    map[string]string{api.CassNodeState: stateDecommissioning},
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{{Name: "cassandra"}},
			Volumes: []corev1.Volume{{
				Name: "server-data",
				VolumeSource: corev1.VolumeSource{
					PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: pvcName},
				},
			}},
		},
		Status: corev1.PodStatus{
			ContainerStatuses: []corev1.ContainerStatus{{Name: "cassandra", Ready: true}},
		},
	}
}

func pvcExists(t *testing.T, rc *ReconciliationContext, name string) bool {
	t.Helper()
	err := rc.Client.Get(rc.Ctx, types.NamespacedName{Name: name, Namespace: rc.Datacenter.Namespace},
		&corev1.PersistentVolumeClaim{})
	if err == nil {
		return true
	}
	if apierrors.IsNotFound(err) {
		return false
	}
	t.Fatalf("unexpected error reading PVC %s: %v", name, err)
	return false
}

// Test 2 (end-to-end): transient mgmt error -> empty metadata (via the REAL
// getCassMetadataEndpoints) -> CheckDecommissioningNodes deletes the PVC while the
// node has never been observed LEFT. This is the NoDataLossOnDecommission violation
// (MC state 7: pvc_exists=FALSE, ring_state="Normal", authoritative_removal_observed=FALSE).
func TestMC2_PrematurePVCDeletion_TransientMetadataError(t *testing.T) {
	rc, _, cleanup := setupTest()
	defer cleanup()

	rc.Datacenter.SetCondition(api.DatacenterCondition{
		Status: corev1.ConditionTrue,
		Type:   api.DatacenterScalingDown,
	})

	// Fake mgmt API: /metadata/endpoints transiently returns HTTP 500.
	server := newFakeMgmtApiServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v0/metadata/endpoints":
			w.WriteHeader(http.StatusInternalServerError) // transient mgmt error
		default:
			w.WriteHeader(http.StatusOK)
			_, _ = io.WriteString(w, "OK")
		}
	}))
	rc.NodeMgmtClient = server.client(rc.ReqLogger)

	pvcName := "server-data-pod-1"
	pvc := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{Name: pvcName, Namespace: rc.Datacenter.Namespace},
	}
	if err := rc.Client.Create(rc.Ctx, pvc); err != nil {
		t.Fatalf("failed to seed PVC: %v", err)
	}

	pod := newDecommissioningPodWithPVC(rc.Datacenter.Namespace, pvcName)
	server.attachToPod(t, pod) // sets PodIP + mgmt-api-http port at the fake server
	rc.clusterPods = []*corev1.Pod{pod}
	rc.dcPods = []*corev1.Pod{pod}

	// Matching StatefulSet (empty rack label matches the pod) so cleanup reaches DeletePodPvcs.
	one := int32(1)
	rc.statefulSets = []*appsv1.StatefulSet{{
		ObjectMeta: metav1.ObjectMeta{Name: "ss-1"},
		Spec:       appsv1.StatefulSetSpec{Replicas: &one},
	}}

	// REAL code path: transient mgmt error => empty ring metadata (MC state 2).
	epData := rc.getCassMetadataEndpoints()
	if len(epData.Entity) != 0 {
		t.Fatalf("precondition: expected EMPTY metadata from transient error, got %d entities", len(epData.Entity))
	}
	t.Logf("getCassMetadataEndpoints() returned EMPTY metadata (transient mgmt error) -- node never observed LEFT")

	if !pvcExists(t, rc, pvcName) {
		t.Fatalf("precondition: PVC should exist before reconcile")
	}

	// The reconcile step that decides decommission completion.
	rc.CheckDecommissioningNodes(epData)

	if pvcExists(t, rc, pvcName) {
		t.Fatalf("bug NOT reproduced: PVC still present (expected premature deletion)")
	}
	t.Logf("BUG REPRODUCED: PVC %q was DELETED after a transient metadata error,", pvcName)
	t.Logf("               although the node was never observed LEFT the ring -> DATA LOSS")
	t.Logf("               (NoDataLossOnDecommission violated; matches MC state 7).")
}

// Test 3 (negative control): identical flow, but the mgmt API is healthy and reports
// the node NORMAL. IsDoneDecommissioning is false, cleanup does not run, and the PVC
// is retained. Proves the deletion in Test 2 is caused by the empty metadata, not the
// test scaffolding.
func TestMC2_Control_HealthyMetadata_PVCRetained(t *testing.T) {
	rc, _, cleanup := setupTest()
	defer cleanup()

	rc.Datacenter.SetCondition(api.DatacenterCondition{
		Status: corev1.ConditionTrue,
		Type:   api.DatacenterScalingDown,
	})

	pvcName := "server-data-pod-1"
	pod := newDecommissioningPodWithPVC(rc.Datacenter.Namespace, pvcName)

	// Healthy mgmt API: report THIS node as NORMAL (still in the ring).
	server := newFakeMgmtApiServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v0/metadata/endpoints":
			w.Header().Set("Content-Type", "application/json")
			// pod.Status.PodIP is set by attachToPod before any request is served.
			_, _ = io.WriteString(w, `{"entity":[{"RPC_ADDRESS":"`+pod.Status.PodIP+`","STATUS":"NORMAL","HOST_ID":"host-1"}]}`)
		default:
			w.WriteHeader(http.StatusOK)
			_, _ = io.WriteString(w, "OK")
		}
	}))
	rc.NodeMgmtClient = server.client(rc.ReqLogger)

	pvc := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{Name: pvcName, Namespace: rc.Datacenter.Namespace},
	}
	if err := rc.Client.Create(rc.Ctx, pvc); err != nil {
		t.Fatalf("failed to seed PVC: %v", err)
	}

	server.attachToPod(t, pod)
	rc.clusterPods = []*corev1.Pod{pod}
	rc.dcPods = []*corev1.Pod{pod}
	one := int32(1)
	rc.statefulSets = []*appsv1.StatefulSet{{
		ObjectMeta: metav1.ObjectMeta{Name: "ss-1"},
		Spec:       appsv1.StatefulSetSpec{Replicas: &one},
	}}

	epData := rc.getCassMetadataEndpoints()
	if len(epData.Entity) == 0 {
		t.Fatalf("control precondition: expected NON-empty metadata from healthy mgmt API")
	}

	rc.CheckDecommissioningNodes(epData)

	if !pvcExists(t, rc, pvcName) {
		t.Fatalf("control failed: PVC was deleted while node is NORMAL (should be retained)")
	}
	t.Logf("CONTROL: node observed NORMAL => PVC retained (no premature deletion). Correct behavior.")
}
