// Reproduction artifact for finding MC-6 — "Pod stuck Starting forever after a lost /start".
// Source: model-checking counterexample spec/output/MC_hunt_scenario3.out (invariant NoStuckStarting).
// Target: k8ssandra/cass-operator, pkg/reconciliation/reconcile_racks.go.
//
// HOW TO RUN (must live in-package to reach unexported reconcile helpers):
//   cp test_bugMC-6_stuck_starting_after_lost_start.go \
//        <repo>/pkg/reconciliation/zz_bugmc6_repro_test.go
//   cd <repo> && go test ./pkg/reconciliation/ -run TestBugMC6_StuckStartingForeverAfterLostStart -race -count=1 -v
//
// OBSERVED RESULT (Level 2 state injection; the injected post-crash state is produced by the
// REAL startCassandra + an operator crash that abandons the in-flight /start == CE S3->S4):
//   zz_bugmc6_repro_test.go:163: MC-6 REPRODUCED: pod "startup-pod" stuck in "Starting" after
//       5 recovery reconciles; deleteStuckNodes never fired; /start re-issued 0 times
//   ...  Deleting stuck pod: startup-pod. Reason: Pod got stuck after Cassandra container terminated
//   zz_bugmc6_repro_test.go:183: Control: with LastState=Terminated (issue #806) deleteStuckNodes
//       fires (deleted=true); MC-6's live-container variant does not.
//   --- PASS: TestBugMC6_StuckStartingForeverAfterLostStart (1.59s)   [go test -race: no data race]
//
package reconciliation

// Reproduction for finding MC-6: "Pod stuck Starting forever after a lost /start".
//
// Counterexample (spec/output/MC_hunt_scenario3.out, invariant NoStuckStarting):
//   S2 remote_state=InFlight (/start goroutine launched)
//   S3 startup_label=Starting, durable_marker=StartupStarting (label persisted)
//   S4 MCControllerCrash -> controller_up=FALSE, remote_state=Lost (in-flight /start abandoned)
// On recovery the pod is labeled Starting but was never actually started, and the
// reconciler wedges: findStartingNodes returns "still starting" forever and no path
// ever re-issues /start.
//
// Escalation level: Level 2 (state injection). The injected post-crash state is produced
// by the REAL production function startCassandra (which persists the Starting label and
// launches the /start goroutine) plus an operator crash that abandons the in-flight
// /start -- exactly CE steps S3->S4. The cassandra container stays Running (NOT
// terminated), which is what distinguishes MC-6 from the already-fixed issue #806
// (container-terminated), whose fix (deleteStuckNodes/hasCassandraContainerTerminated)
// does not fire here.

import (
	"context"
	"io"
	"net/http"
	"testing"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	api "github.com/k8ssandra/cass-operator/apis/cassandra/v1beta1"
	"github.com/k8ssandra/cass-operator/pkg/httphelper"
)

func mc6CountStartCalls(s *fakeMgmtApiServer) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for _, c := range s.calls {
		if c.RequestPath == "/api/v0/lifecycle/start" {
			n++
		}
	}
	return n
}

func TestBugMC6_StuckStartingForeverAfterLostStart(t *testing.T) {
	// Shared "durable store" == the k8s API server that survives the operator crash.
	// Built first so both operator instances (pre-crash / restarted) share it.
	rcA, _, cleanupA := setupTest()
	t.Cleanup(cleanupA)

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "startup-pod",
			Namespace: rcA.Datacenter.Namespace,
			Labels:    map[string]string{api.CassNodeState: stateReadyToStart},
		},
		Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "cassandra"}}},
		// cassandra container (mgmt-api) is Running but cassandra itself is not ready;
		// crucially it has NEVER terminated (LastTerminationState empty).
		Status: corev1.PodStatus{
			ContainerStatuses: []corev1.ContainerStatus{{
				Name:  "cassandra",
				Ready: false,
				State: corev1.ContainerState{Running: &corev1.ContainerStateRunning{StartedAt: metav1.Now()}},
			}},
		},
	}

	store := fake.NewClientBuilder().
		WithScheme(setupScheme()).
		WithStatusSubresource(rcA.Datacenter, pod).
		WithRuntimeObjects(rcA.Datacenter, pod).
		WithIndex(&corev1.Pod{}, podPVCClaimNameField, podPVCClaimNames).
		Build()

	// ---------- Phase A: pre-crash operator issues /start and writes the durable Starting label ----------
	// serverA's /start handler BLOCKS: this models the /start call that is in flight when the
	// operator crashes and is then lost (CE S4 remote_state=Lost). It never bootstraps cassandra.
	releaseA := make(chan struct{})
	serverA := startFakeMgmtApiTestServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v0/lifecycle/start" {
			w.WriteHeader(http.StatusOK)
			_, _ = io.WriteString(w, "OK")
			return
		}
		<-releaseA // the in-flight /start the crash abandons
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, "OK")
	}))
	// Release the abandoned goroutine and close serverA only after all assertions.
	defer func() { close(releaseA); serverA.Close() }()

	serverA.attachToPod(t, pod)
	rcA.Client = store
	rcA.NodeMgmtClient = serverA.client(rcA.ReqLogger)

	// REAL production path: launches the /start goroutine (InFlight) and persists Starting.
	require.NoError(t, rcA.startCassandra(httphelper.CassMetadataEndpoints{}, pod))

	afterLabel := &corev1.Pod{}
	require.NoError(t, store.Get(context.Background(), client.ObjectKeyFromObject(pod), afterLabel))
	require.Equal(t, stateStarting, afterLabel.Labels[api.CassNodeState],
		"precondition: real startCassandra must persist the durable Starting label")
	require.False(t, isServerReady(afterLabel), "precondition: cassandra never became ready (/start lost)")

	// ---------- Phase B: operator restarts; in-flight /start goroutine is gone; run recovery ----------
	// Fresh operator instance rcB sharing the same durable store, with a mgmt client that RECORDS
	// calls so we can prove /start is never re-issued.
	rcB, _, cleanupB := setupTest()
	t.Cleanup(cleanupB)
	serverB := newFakeMgmtApiServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, "OK")
	}))
	rcB.Client = store
	rcB.NodeMgmtClient = serverB.client(rcB.ReqLogger)

	const iterations = 5
	for i := 0; i < iterations; i++ {
		// Restarted operator rebuilds its pod cache from the durable store each reconcile.
		fresh := &corev1.Pod{}
		require.NoError(t, store.Get(context.Background(), client.ObjectKeyFromObject(pod), fresh))
		serverB.attachToPod(t, fresh)
		rcB.dcPods = []*corev1.Pod{fresh}
		rcB.clusterPods = []*corev1.Pod{fresh}

		// Exactly the recovery order inside CheckPodsReady (reconcile_racks.go:749,759,795):
		nsnr, err := rcB.findStartedNotReadyNodes()
		require.NoError(t, err)
		require.False(t, nsnr, "iter %d: findStartedNotReadyNodes ignores a Starting pod (only acts on Started)", i)

		deleted, err := rcB.deleteStuckNodes()
		require.NoError(t, err)
		require.False(t, deleted,
			"iter %d: deleteStuckNodes must NOT fire — container is alive/not terminated; the #806 fix does not cover this", i)

		starting, transitioned, err := rcB.findStartingNodes()
		require.NoError(t, err)
		require.True(t, starting,
			"iter %d: findStartingNodes returns still-starting -> CheckPodsReady RequeueSoon and returns early (reconcile_racks.go:1972,1981)", i)
		require.False(t, transitioned, "iter %d: pod never transitions to Started", i)

		check := &corev1.Pod{}
		require.NoError(t, store.Get(context.Background(), client.ObjectKeyFromObject(pod), check),
			"iter %d: pod must still exist (never deleted)", i)
		require.Equal(t, stateStarting, check.Labels[api.CassNodeState], "iter %d: pod is stuck in Starting", i)
	}

	// PROOF the bug is live and permanent: across every recovery reconcile, /start was never
	// re-issued (startCassandra at reconcile_racks.go:2042 is only reached for pods NOT yet
	// labeled Starting, and findStartingNodes returned early before it).
	require.Equal(t, 0, mc6CountStartCalls(serverB),
		"the operator must re-issue /start to recover, but it never did => STUCK STARTING FOREVER")

	final := &corev1.Pod{}
	require.NoError(t, store.Get(context.Background(), client.ObjectKeyFromObject(pod), final))
	require.Equal(t, stateStarting, final.Labels[api.CassNodeState])
	require.False(t, isServerReady(final))
	t.Logf("MC-6 REPRODUCED: pod %q stuck in %q after %d recovery reconciles; deleteStuckNodes never fired; /start re-issued %d times",
		final.Name, final.Labels[api.CassNodeState], iterations, mc6CountStartCalls(serverB))

	// ---------- Contrast control: MC-6 is distinct from the already-fixed #806 ----------
	// Had the cassandra CONTAINER terminated (issue #806), deleteStuckNodes WOULD delete the pod
	// and k8s would recreate it (recovery). MC-6's live-container variant evades that fix.
	term := &corev1.Pod{}
	require.NoError(t, store.Get(context.Background(), client.ObjectKeyFromObject(pod), term))
	term.Status.ContainerStatuses = []corev1.ContainerStatus{{
		Name:                 "cassandra",
		Ready:                false,
		State:                corev1.ContainerState{Running: &corev1.ContainerStateRunning{StartedAt: metav1.Now()}},
		LastTerminationState: corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{ExitCode: 143, Reason: "Error"}},
	}}
	rcB.dcPods = []*corev1.Pod{term}
	rcB.clusterPods = []*corev1.Pod{term}
	deletedTerm, err := rcB.deleteStuckNodes()
	require.NoError(t, err)
	require.True(t, deletedTerm,
		"#806 control: a Starting pod whose container TERMINATED is deleted by deleteStuckNodes; MC-6 (container alive) is not")
	t.Logf("Control: with LastState=Terminated (issue #806) deleteStuckNodes fires (deleted=%v); MC-6's live-container variant does not.", deletedTerm)
}
