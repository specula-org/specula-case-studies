#!/usr/bin/env bash
#
# Reproduction for finding MC-5:
#   "Double async job — maintenance task submitted twice when the job id isn't
#    checkpointed" (invariant AtMostOnceRemoteOp,
#    spec/output/MC_hunt_scenario3_maintenance.out).
#
# Mechanism: internal/controllers/control/cassandratask_controller.go
#   - startPodTask submits the async mgmt job (remote side-effect, l.757) and stores the
#     returned job id only in the in-memory status copy (l.762 / l.840).
#   - processRack persists it durably only later, via r.Status().Patch (l.713).
#   - If that patch fails (or the controller crashes) before the job id is durable, the next
#     reconcile re-reads the durable object (no job id) and re-submits -> a SECOND remote job
#     runs for one logical pod-task. Remote submission is not at-most-once.
#
# Escalation level: 1 (realistic fault injection).
#   - Real code path: processRack -> startPodTask -> callCleanup -> CallKeyspaceCleanup ->
#     POST /api/v1/ops/keyspace/cleanup (no system logic modified).
#   - Injected fault: the FIRST Status().Patch fails, via controller-runtime's official
#     interceptor.Funcs. A status-patch failure (API-server 5xx / conflict / crash) is a normal
#     production fault, so the injected precondition is reachable through the real reconcile loop.
#   - The two processRack calls with a durable re-Get in between model two reconcile iterations,
#     exactly as controller-runtime re-Gets the object at the top of each Reconcile.
#
# The test FAILS (non-zero go test exit) when the bug reproduces; its failure message contains
# the marker "BUG REPRODUCED". This script prints the raw go test output as evidence and exits 0
# iff the marker is present.

set -uo pipefail

REPO="${1:?Usage: test_bugMC-5_double_submit.sh /path/to/cass-operator}"
PKG_DIR="${REPO}/internal/controllers/control"
TEST_FILE="${PKG_DIR}/zz_bug_mc5_repro_test.go"

cleanup() { rm -f "${TEST_FILE}"; }
trap cleanup EXIT

cat > "${TEST_FILE}" <<'GOTEST'
package control

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"

	api "github.com/k8ssandra/cass-operator/apis/control/v1alpha1"
	"github.com/k8ssandra/cass-operator/pkg/httphelper"
)

// countingMgmtClient stands in for the Cassandra management API (the real remote consumer).
// It counts POSTs to the cleanup endpoint = number of remote cleanup jobs actually created on
// the node, and serves the features endpoint that startPodTask queries.
type countingMgmtClient struct {
	mu       sync.Mutex
	cleanups int32
	jobIDs   []string
}

func (c *countingMgmtClient) Do(req *http.Request) (*http.Response, error) {
	resp := func(body string, code int) *http.Response {
		return &http.Response{
			StatusCode: code,
			Body:       io.NopCloser(strings.NewReader(body)),
			Header:     http.Header{"Content-Type": []string{"application/json"}},
		}
	}
	switch {
	case req.URL.Path == "/api/v0/metadata/versions/features":
		return resp(`{"cassandra_version":"4.1","features":["async_sstable_tasks"]}`, http.StatusOK), nil
	case req.Method == http.MethodPost && req.URL.Path == "/api/v1/ops/keyspace/cleanup":
		n := atomic.AddInt32(&c.cleanups, 1)
		id := fmt.Sprintf("remote-job-%d", n)
		c.mu.Lock()
		c.jobIDs = append(c.jobIDs, id)
		c.mu.Unlock()
		return resp(id, http.StatusOK), nil // mgmt-api returns the job id as the body
	default:
		return resp("not found", http.StatusNotFound), nil
	}
}

func TestBugMC5DoubleAsyncSubmission(t *testing.T) {
	scheme := speculaControlScheme(t) // reuse the package's test scheme helper

	task := &api.CassandraTask{
		ObjectMeta: metav1.ObjectMeta{Name: "maintenance-task", Namespace: "default"},
		Status:     api.CassandraTaskStatus{PodStatuses: map[string]api.PodProcessingStatus{}},
	}

	var statusPatchCalls int32
	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithStatusSubresource(task).
		WithRuntimeObjects(task).
		WithInterceptorFuncs(interceptor.Funcs{
			SubResourcePatch: func(
				ctx context.Context,
				cl client.Client,
				subResourceName string,
				obj client.Object,
				patch client.Patch,
				opts ...client.SubResourcePatchOption,
			) error {
				// Fail ONLY the first durable status patch (cassandratask_controller.go l.713),
				// modeling a transient API-server error / crash between the remote submit
				// (l.757) and the durable checkpoint (l.713).
				if subResourceName == "status" && atomic.AddInt32(&statusPatchCalls, 1) == 1 {
					return errors.New("injected status patch failure")
				}
				return cl.SubResource(subResourceName).Patch(ctx, obj, patch, opts...)
			},
		}).
		Build()

	mgmt := &countingMgmtClient{}
	nodeClient := httphelper.NodeMgmtClient{Client: mgmt, Log: logr.Discard(), Protocol: "http"}

	pod := corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "maintenance-pod", Namespace: "default"},
		Spec: corev1.PodSpec{Containers: []corev1.Container{{
			Name:  "cassandra",
			Ports: []corev1.ContainerPort{{Name: "mgmt-api-http", ContainerPort: 8080}},
		}}},
		Status: corev1.PodStatus{PodIP: "127.0.0.1"},
	}
	config := &TaskConfiguration{
		Job:          api.CommandCleanup,
		AsyncFeature: httphelper.AsyncSSTableTasks,
		AsyncFunc:    callCleanup, // the REAL production remote-submit function
	}
	reconciler := &CassandraTaskReconciler{Client: fakeClient, Scheme: scheme}
	key := client.ObjectKeyFromObject(task)
	ctx := context.Background()

	// ---- Reconcile #1: submits the remote cleanup job, then the durable status patch fails.
	liveTask := &api.CassandraTask{}
	if err := fakeClient.Get(ctx, key, liveTask); err != nil {
		t.Fatalf("get task: %v", err)
	}
	_, _, _, _, err1 := reconciler.processRack(ctx, liveTask, []corev1.Pod{pod}, config, nodeClient, 1)
	if err1 == nil {
		t.Fatalf("reconcile #1: expected the injected status-patch failure, got nil")
	}
	t.Logf("reconcile #1 returned error (durable status patch failed as injected): %v", err1)
	t.Logf("remote cleanup submissions after reconcile #1: %d %v", atomic.LoadInt32(&mgmt.cleanups), mgmt.jobIDs)

	// The durable object the next reconcile re-reads has NO job id, because the patch failed.
	durable := &api.CassandraTask{}
	if err := fakeClient.Get(ctx, key, durable); err != nil {
		t.Fatalf("get durable task: %v", err)
	}
	ps, ok := durable.Status.PodStatuses[pod.Name]
	t.Logf("durable PodStatuses[%q]: exists=%v jobID=%q (job id was NOT checkpointed)", pod.Name, ok, ps.JobID)
	if ok && ps.JobID != "" {
		t.Fatalf("precondition not met: durable status unexpectedly has job id %q", ps.JobID)
	}

	// ---- Reconcile #2: controller re-reads durable state (no job id) and RE-SUBMITS.
	fresh := &api.CassandraTask{}
	if err := fakeClient.Get(ctx, key, fresh); err != nil {
		t.Fatalf("get fresh task: %v", err)
	}
	if _, _, _, _, err2 := reconciler.processRack(ctx, fresh, []corev1.Pod{pod}, config, nodeClient, 1); err2 != nil {
		t.Fatalf("reconcile #2 unexpected error: %v", err2)
	}

	total := atomic.LoadInt32(&mgmt.cleanups)
	t.Logf("remote cleanup submissions after reconcile #2: %d %v", total, mgmt.jobIDs)

	tracked := &api.CassandraTask{}
	_ = fakeClient.Get(ctx, key, tracked)
	trackedID := tracked.Status.PodStatuses[pod.Name].JobID
	t.Logf("durable tracked jobID after reconcile #2: %q", trackedID)

	// Expected correct behaviour: at most ONE remote cleanup job per logical pod-task.
	if total >= 2 {
		orphaned := "<none>"
		if len(mgmt.jobIDs) > 0 {
			orphaned = mgmt.jobIDs[0]
		}
		t.Errorf("BUG REPRODUCED (AtMostOnceRemoteOp violated): one logical pod-task caused %d remote cleanup jobs %v on the node; "+
			"operator now tracks only %q and has permanently lost track of %q (two overlapping cleanups run for one CassandraTask pod-task)",
			total, mgmt.jobIDs, trackedID, orphaned)
	} else {
		t.Logf("only %d remote submission(s) — bug not triggered", total)
	}
}
GOTEST

echo "=== Running MC-5 reproduction (go test) ==="
cd "${REPO}" || { echo "repo not found: ${REPO}"; exit 2; }

OUT="$(timeout 420 go test ./internal/controllers/control/ -run '^TestBugMC5DoubleAsyncSubmission$' -v -count=1 2>&1)"
STATUS=$?
echo "${OUT}"
echo "=== go test exit status: ${STATUS} (timeout=124) ==="

if echo "${OUT}" | grep -q "BUG REPRODUCED"; then
	echo ">>> REPRODUCTION CONFIRMED: two remote cleanup submissions for one logical pod-task (AtMostOnceRemoteOp violated)."
	exit 0
fi

if [ "${STATUS}" -eq 124 ]; then
	echo ">>> TIMEOUT while running the reproduction."
else
	echo ">>> Bug NOT reproduced (no double submission observed)."
fi
exit 1
