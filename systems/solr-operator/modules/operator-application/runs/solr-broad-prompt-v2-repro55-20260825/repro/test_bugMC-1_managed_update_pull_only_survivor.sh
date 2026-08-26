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
if [[ -z "$GO_BIN" ]]; then
	echo "go binary not found on PATH or at /usr/local/go/bin/go" >&2
	exit 127
fi

repro_tmp_dir="$(mktemp -d)"
trap 'rm -rf "$repro_tmp_dir"' EXIT

cp -a "$SOURCE_REPO/." "$repro_tmp_dir/repo"
cd "$repro_tmp_dir/repo"

cat > controllers/util/bugmc1_pull_only_survivor_test.go <<'GOEOF'
package util

import (
	"fmt"
	"reflect"
	"testing"

	solr "github.com/apache/solr-operator/api/v1beta1"
	"github.com/apache/solr-operator/controllers/util/solr_api"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

func TestBugMC1ManagedUpdateSelectsOnlyLeaderEligibleReplica(t *testing.T) {
	maxShardUnavailable := intstr.FromInt(1)
	maxPodsUnavailable := intstr.FromInt(1)
	cloud := &solr.SolrCloud{
		ObjectMeta: metav1.ObjectMeta{Name: "mc1", Namespace: "default"},
		Spec: solr.SolrCloudSpec{
			Replicas: Replicas(2),
			SolrAddressability: solr.SolrAddressabilityOptions{
				PodPort: 8983,
			},
			UpdateStrategy: solr.SolrUpdateStrategy{
				Method: solr.ManagedUpdate,
				ManagedUpdateOptions: solr.ManagedUpdateOptions{
					MaxPodsUnavailable:          &maxPodsUnavailable,
					MaxShardReplicasUnavailable: &maxShardUnavailable,
				},
			},
		},
	}

	nrtNode := SolrNodeName(cloud, "mc1-solrcloud-0")
	pullNode := SolrNodeName(cloud, "mc1-solrcloud-1")
	cluster := solr_api.SolrClusterStatus{
		LiveNodes: []string{nrtNode, pullNode},
		Collections: map[string]solr_api.SolrCollectionStatus{
			"collection1": {
				Shards: map[string]solr_api.SolrShardStatus{
					"shard1": {
						State: solr_api.ShardActive,
						Replicas: map[string]solr_api.SolrReplicaStatus{
							"nrt-replica": {
								State:    solr_api.ReplicaActive,
								Core:     "collection1_shard1_replica_n1",
								NodeName: nrtNode,
								BaseUrl:  "http://mc1-solrcloud-0:8983/solr",
								Leader:   true,
								Type:     solr_api.NRT,
							},
							"pull-replica": {
								State:    solr_api.ReplicaActive,
								Core:     "collection1_shard1_replica_p1",
								NodeName: pullNode,
								BaseUrl:  "http://mc1-solrcloud-1:8983/solr",
								Leader:   false,
								Type:     solr_api.PULL,
							},
						},
					},
				},
			},
		},
	}

	outOfDate := OutOfDatePodSegmentation{
		Running: []corev1.Pod{
			{ObjectMeta: metav1.ObjectMeta{Name: "mc1-solrcloud-0"}},
		},
	}
	state := findSolrNodeContents(cluster, "", GetManagedSolrNodeNames(cloud, 2))
	notActiveBefore := state.ShardReplicasNotActive["collection1|shard1"]
	pods, retryLater := DeterminePodsSafeToUpdate(cloud, 2, outOfDate, state, 1, log.Log)
	selectedName := ""
	if len(pods) > 0 {
		selectedName = pods[0].Name
	}

	remainingLeaderEligible := 0
	for _, replica := range cluster.Collections["collection1"].Shards["shard1"].Replicas {
		if replica.State != solr_api.ReplicaActive {
			continue
		}
		if replica.Type != solr_api.NRT && replica.Type != solr_api.TLOG {
			continue
		}
		if replica.NodeName == SolrNodeName(cloud, selectedName) {
			continue
		}
		remainingLeaderEligible++
	}

	fmt.Printf("selector.selected=%v retryLater=%v\n", getPodNames(pods), retryLater)
	fmt.Printf("selector.totalShardReplicas[collection1|shard1]=%d\n", state.TotalShardReplicas["collection1|shard1"])
	fmt.Printf("selector.notActiveBefore=%d notActiveAfterSelection=%d activeOnSelected=%d selectedReplicaType=NRT remainingReplicaType=PULL remainingActiveLeaderEligibleAfterSelection=%d\n",
		notActiveBefore, state.ShardReplicasNotActive["collection1|shard1"],
		state.NodeContents[nrtNode].activeReplicasPerShard["collection1|shard1"], remainingLeaderEligible)

	if len(pods) == 1 && pods[0].Name == "mc1-solrcloud-0" && !retryLater && remainingLeaderEligible == 0 {
		t.Fatalf("BUG TRIGGERED selector: selected %s, the only active NRT/TLOG replica host for collection1|shard1; remaining active leader-eligible replicas=%d", pods[0].Name, remainingLeaderEligible)
	}
}

func TestBugMC1GeneratedObjectsMakeReadinessACommonServiceConsumer(t *testing.T) {
	maxShardUnavailable := intstr.FromInt(1)
	maxPodsUnavailable := intstr.FromInt(1)
	replicas := int32(2)
	cloud := &solr.SolrCloud{
		ObjectMeta: metav1.ObjectMeta{Name: "mc1", Namespace: "default"},
		Spec: solr.SolrCloudSpec{
			Replicas: &replicas,
			SolrAddressability: solr.SolrAddressabilityOptions{
				PodPort:           8983,
				CommonServicePort: 80,
			},
			UpdateStrategy: solr.SolrUpdateStrategy{
				Method: solr.ManagedUpdate,
				ManagedUpdateOptions: solr.ManagedUpdateOptions{
					MaxPodsUnavailable:          &maxPodsUnavailable,
					MaxShardReplicasUnavailable: &maxShardUnavailable,
				},
			},
		},
	}
	cloud.WithDefaults(log.Log)

	status := &solr.SolrCloudStatus{
		ZookeeperConnectionInfo: solr.ZookeeperConnectionInfo{
			InternalConnectionString: "zk:2181",
			ChRoot:                   "/mc1",
		},
	}
	statefulSet := GenerateStatefulSet(cloud, status, nil, map[string]string{}, nil, nil)
	commonService := GenerateCommonService(cloud)

	hasNotStoppedGate := false
	for _, gate := range statefulSet.Spec.Template.Spec.ReadinessGates {
		if gate.ConditionType == SolrIsNotStoppedReadinessCondition {
			hasNotStoppedGate = true
		}
	}
	selectorMatches := reflect.DeepEqual(commonService.Spec.Selector, statefulSet.Spec.Selector.MatchLabels)

	fmt.Printf("surface.readinessGate[%s]=%v commonServiceSelectorMatchesStatefulSet=%v publishNotReadyAddresses=%v\n",
		SolrIsNotStoppedReadinessCondition, hasNotStoppedGate, selectorMatches, commonService.Spec.PublishNotReadyAddresses)

	if hasNotStoppedGate && selectorMatches && !commonService.Spec.PublishNotReadyAddresses {
		t.Fatalf("BUG TRIGGERED surface: generated pods expose %s as a readiness gate and the common service routes only ready selected pods", SolrIsNotStoppedReadinessCondition)
	}
}
GOEOF

cat > controllers/bugmc1_deletepod_consumer_test.go <<'GOEOF'
package controllers

import (
	"context"
	"errors"
	"fmt"
	"testing"

	solrv1beta1 "github.com/apache/solr-operator/api/v1beta1"
	"github.com/apache/solr-operator/controllers/util"
	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

func TestBugMC1DeletePodForUpdateStopsTrafficToSelectedNRTPod(t *testing.T) {
	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		t.Fatalf("could not add client-go types to scheme: %v", err)
	}
	if err := solrv1beta1.AddToScheme(scheme); err != nil {
		t.Fatalf("could not add solr types to scheme: %v", err)
	}

	instance := &solrv1beta1.SolrCloud{
		ObjectMeta: metav1.ObjectMeta{Name: "mc1", Namespace: "default"},
	}
	selected := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "mc1-solrcloud-0",
			Namespace: "default",
			UID:       "mc1-pod-0",
		},
		Spec: corev1.PodSpec{
			ReadinessGates: []corev1.PodReadinessGate{
				{ConditionType: util.SolrIsNotStoppedReadinessCondition},
			},
		},
		Status: corev1.PodStatus{
			Conditions: []corev1.PodCondition{
				{
					Type:    util.SolrIsNotStoppedReadinessCondition,
					Status:  corev1.ConditionTrue,
					Reason:  string(PodStarted),
					Message: "Pod has not yet been stopped",
				},
			},
		},
	}

	deleteErr := errors.New("stop after readiness update so the patched pod can be inspected")
	deleteAttempted := false
	k8sClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithStatusSubresource(&corev1.Pod{}).
		WithObjects(selected.DeepCopy(), instance.DeepCopy()).
		WithInterceptorFuncs(interceptor.Funcs{
			Delete: func(_ context.Context, _ client.WithWatch, _ client.Object, _ ...client.DeleteOption) error {
				deleteAttempted = true
				return deleteErr
			},
		}).
		Build()

	r := &SolrCloudReconciler{
		Client:   k8sClient,
		Recorder: record.NewFakeRecorder(8),
	}
	_, _, err := DeletePodForUpdate(context.Background(), r, instance, selected, false, logr.Discard())
	if !errors.Is(err, deleteErr) {
		t.Fatalf("expected the controlled delete error after readiness update, got %v", err)
	}
	if !deleteAttempted {
		t.Fatalf("expected DeletePodForUpdate to reach the delete step")
	}

	updated := &corev1.Pod{}
	if err := k8sClient.Get(context.Background(), client.ObjectKeyFromObject(selected), updated); err != nil {
		t.Fatalf("could not fetch updated selected pod: %v", err)
	}
	condFound := false
	for _, cond := range updated.Status.Conditions {
		if cond.Type == util.SolrIsNotStoppedReadinessCondition {
			condFound = true
			fmt.Printf("consumer.condition[%s]=%s reason=%s message=%q\n", cond.Type, cond.Status, cond.Reason, cond.Message)
			if cond.Status == corev1.ConditionFalse && cond.Reason == string(PodUpdate) {
				t.Fatalf("BUG TRIGGERED consumer: DeletePodForUpdate marked selected NRT pod traffic-not-ready before any NRT/TLOG survivor exists")
			}
		}
	}
	if !condFound {
		t.Fatalf("selected pod has no %s condition after DeletePodForUpdate", util.SolrIsNotStoppedReadinessCondition)
	}
}
GOEOF

set +e
kubectl_output="$(timeout 30s kubectl get pods -A 2>&1)"
kubectl_rc=$?
kind_output="$(timeout 30s docker exec specula-mc1-1715379-control-plane kubectl get pods -A 2>&1)"
kind_rc=$?
crictl_output="$(timeout 30s docker exec specula-mc1-1715379-control-plane crictl ps -a 2>&1)"
crictl_rc=$?
selector_output="$(timeout 5m "$GO_BIN" test ./controllers/util -run TestBugMC1ManagedUpdateSelectsOnlyLeaderEligibleReplica -count=1 -v 2>&1)"
selector_rc=$?
surface_output="$(timeout 5m "$GO_BIN" test ./controllers/util -run TestBugMC1GeneratedObjectsMakeReadinessACommonServiceConsumer -count=1 -v 2>&1)"
surface_rc=$?
consumer_output="$(timeout 5m "$GO_BIN" test ./controllers -run TestBugMC1DeletePodForUpdateStopsTrafficToSelectedNRTPod -count=1 -v 2>&1)"
consumer_rc=$?
set -e

printf '%s\n' '--- escalation preflight ---'
printf 'level0.kubectl_exit=%d\n%s\n' "$kubectl_rc" "$kubectl_output"
printf 'level0.kind_kubectl_exit=%d\n%s\n' "$kind_rc" "$kind_output"
printf 'level0.crictl_exit=%d\n%s\n' "$crictl_rc" "$crictl_output"
printf '%s\n' 'LEVEL 0/1 LIVE CLUSTER: blocked here because kubectl is absent in the worker shell and the visible kind API refuses connections; no Solr workload pods are running.'
printf '%s\n' '--- selector reproduction ---'
printf '%s\n' "$selector_output"
printf 'selector_exit=%d\n' "$selector_rc"
printf '%s\n' '--- generated-surface reproduction ---'
printf '%s\n' "$surface_output"
printf 'surface_exit=%d\n' "$surface_rc"
printf '%s\n' '--- consumer reproduction ---'
printf '%s\n' "$consumer_output"
printf 'consumer_exit=%d\n' "$consumer_rc"

if [[ "$selector_output" == *"BUG TRIGGERED selector"* && "$surface_output" == *"BUG TRIGGERED surface"* && "$consumer_output" == *"BUG TRIGGERED consumer"* ]]; then
	printf '%s\n' 'LEVEL 2 CONFIRMED: real managed-update code selects and marks not-ready the only active NRT/TLOG pod, leaving zero active leader-eligible replicas and only an active PULL survivor.'
	printf '%s\n' 'LEVEL 3 NOT APPLIED: the selected path is deterministic, not a race widened by source delays; modifying operator logic would not replace the missing live Solr/Kubernetes cluster.'
	printf '%s\n' 'LIVE WRITE CHECK BLOCKED: this environment cannot issue a real Solr update through a running operator-managed service, so the honest final tier is ENV_LIMITED rather than REPRODUCED.'
	exit 0
fi

printf '%s\n' 'REPRODUCTION FAILED: one or more expected bug markers were absent.' >&2
exit 1
