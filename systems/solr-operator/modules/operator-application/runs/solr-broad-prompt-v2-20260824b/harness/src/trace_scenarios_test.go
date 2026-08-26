// Licensed to the Apache Software Foundation (ASF) under one or more
// contributor license agreements. See the NOTICE file distributed with this
// work for additional information regarding copyright ownership.
// The ASF licenses this file to You under the Apache License, Version 2.0.

package controllers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	solrv1beta1 "github.com/apache/solr-operator/api/v1beta1"
	"github.com/apache/solr-operator/controllers/util"
	"github.com/apache/solr-operator/controllers/util/solr_api"
	"github.com/apache/solr-operator/internal/speculatrace"
	"github.com/go-logr/logr"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/tools/record"
	"k8s.io/utils/pointer"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) { return f(req) }

func traceScenario(t *testing.T, name, family string, fn func(string)) {
	t.Helper()
	dir := os.Getenv("TRACE_DIR")
	if dir == "" {
		t.Fatal("TRACE_DIR must be an absolute directory")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name+".ndjson")
	if err := speculatrace.Start(path, family); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := speculatrace.Close(); err != nil {
			t.Error(err)
		}
	})
	fn(path)
	if err := speculatrace.Close(); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(strings.TrimSpace(string(data))) == 0 {
		t.Fatalf("trace %s is empty", path)
	}
	for lineNo, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		var object map[string]any
		if err := json.Unmarshal([]byte(line), &object); err != nil {
			t.Fatalf("trace line %d is not JSON: %v", lineNo+1, err)
		}
		if object["tag"] != "trace" || object["ts"] == "" {
			t.Fatalf("trace line %d lacks the trace envelope", lineNo+1)
		}
	}
}

func mustRecord(t *testing.T, event string, args ...speculatrace.Args) {
	t.Helper()
	a := speculatrace.Args{}
	if len(args) > 0 {
		a = args[0]
	}
	if err := speculatrace.Record(event, a); err != nil {
		t.Fatalf("record %s: %v", event, err)
	}
}

func traceScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	scheme := runtime.NewScheme()
	if err := corev1.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	if err := appsv1.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	if err := solrv1beta1.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	return scheme
}

func boundedCloud() *solrv1beta1.SolrCloud {
	maxPods := intstr.FromInt(1)
	maxShard := intstr.FromInt(1)
	return &solrv1beta1.SolrCloud{
		ObjectMeta: metav1.ObjectMeta{Name: "trace", Namespace: "default", UID: types.UID("trace-cloud")},
		Spec: solrv1beta1.SolrCloudSpec{
			Replicas:       pointer.Int32(2),
			ZookeeperRef:   &solrv1beta1.ZookeeperRef{ConnectionInfo: &solrv1beta1.ZookeeperConnectionInfo{InternalConnectionString: "zk:2181"}},
			UpdateStrategy: solrv1beta1.SolrUpdateStrategy{Method: solrv1beta1.ManagedUpdate, ManagedUpdateOptions: solrv1beta1.ManagedUpdateOptions{MaxPodsUnavailable: &maxPods, MaxShardReplicasUnavailable: &maxShard}},
		},
	}
}

func newReconciler(scheme *runtime.Scheme, objects ...client.Object) (*SolrCloudReconciler, client.Client) {
	c := fake.NewClientBuilder().WithScheme(scheme).WithStatusSubresource(&corev1.Pod{}, &solrv1beta1.SolrCloud{}, &solrv1beta1.SolrBackup{}).WithObjects(objects...).Build()
	return &SolrCloudReconciler{Client: c, Scheme: scheme, Recorder: record.NewFakeRecorder(100)}, c
}

func jsonResponse(body string) *http.Response {
	return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}
}

func TestTraceManagedUpdateRealControllerPath(t *testing.T) {
	traceScenario(t, "managed-update-consumer-order", "MU", func(_ string) {
		ctx := context.Background()
		cloud := boundedCloud()
		pods := cloud.GetAllSolrPodNames()
		updateNode := util.SolrNodeName(cloud, pods[0])
		pullNode := util.SolrNodeName(cloud, pods[1])
		transport := roundTripFunc(func(req *http.Request) (*http.Response, error) {
			switch req.URL.Query().Get("action") {
			case "CLUSTERSTATUS":
				return jsonResponse(fmt.Sprintf(`{"responseHeader":{"status":0},"cluster":{"collections":{"collection1":{"shards":{"shard1":{"replicas":{"r1":{"state":"active","node_name":%q,"leader":"true","type":"NRT"},"r2":{"state":"active","node_name":%q,"leader":"false","type":"PULL"}}}}}},"live_nodes":[%q,%q]}}`, updateNode, pullNode, updateNode, pullNode)), nil
			case "OVERSEERSTATUS":
				return jsonResponse(fmt.Sprintf(`{"responseHeader":{"status":0},"leader":%q}`, pullNode)), nil
			default:
				return nil, fmt.Errorf("unexpected Solr request %s", req.URL.String())
			}
		})
		solr_api.SetNoVerifyTLSHttpClient(&http.Client{Transport: transport})

		sts := &appsv1.StatefulSet{ObjectMeta: metav1.ObjectMeta{Name: cloud.StatefulSetName(), Namespace: cloud.Namespace, Annotations: map[string]string{}}, Spec: appsv1.StatefulSetSpec{Replicas: pointer.Int32(2)}}
		old := sts.DeepCopy()
		op, _, err := determineRollingUpdateClusterOpLockIfNecessary(cloud, util.OutOfDatePodSegmentation{Running: []corev1.Pod{{ObjectMeta: metav1.ObjectMeta{Name: pods[0]}}}})
		if err != nil || op == nil {
			t.Fatalf("determine rolling operation: %v", err)
		}
		if err := setClusterOpLock(sts, *op); err != nil {
			t.Fatal(err)
		}
		r, c := newReconciler(traceScheme(t), cloud, old)
		foundSTS := &appsv1.StatefulSet{}
		if err := c.Get(ctx, client.ObjectKeyFromObject(old), foundSTS); err != nil {
			t.Fatal(err)
		}
		foundSTS.Annotations = sts.Annotations
		if err := c.Patch(ctx, foundSTS, client.MergeFrom(old)); err != nil {
			t.Fatal(err)
		}
		mustRecord(t, "StartManagedUpdate")

		state, retry, err := util.GetNodeReplicaState(ctx, cloud, sts, true, logr.Discard())
		if err != nil || retry || len(state.NodeContents) != 2 {
			t.Fatalf("real CLUSTERSTATUS aggregation failed: retry=%v err=%v state=%+v", retry, err, state)
		}
		candidate := corev1.Pod{ObjectMeta: metav1.ObjectMeta{Name: pods[0], Namespace: cloud.Namespace, UID: types.UID("old-uid")}, Spec: corev1.PodSpec{ReadinessGates: []corev1.PodReadinessGate{{ConditionType: util.SolrIsNotStoppedReadinessCondition}}}, Status: corev1.PodStatus{Conditions: []corev1.PodCondition{{Type: util.SolrIsNotStoppedReadinessCondition, Status: corev1.ConditionTrue, Reason: string(PodStarted)}}}}
		selected, retry := util.DeterminePodsSafeToUpdate(cloud, 2, util.OutOfDatePodSegmentation{Running: []corev1.Pod{candidate}}, state, 1, logr.Discard())
		if retry || len(selected) != 1 || selected[0].Name != candidate.Name {
			t.Fatalf("real selector result: selected=%v retry=%v", selected, retry)
		}

		r, c = newReconciler(traceScheme(t), cloud, &candidate)
		conditions := map[corev1.PodConditionType]podReadinessConditionChange{util.SolrIsNotStoppedReadinessCondition: {reason: PodUpdate, status: false}, util.SolrReplicasNotEvictedReadinessCondition: {reason: EvictingReplicas, status: false}}
		updated, err := EnsurePodReadinessConditions(ctx, r, cloud, &candidate, conditions, logr.Discard())
		if err != nil || PodConditionEquals(updated, util.SolrIsNotStoppedReadinessCondition, PodStarted) {
			t.Fatalf("real readiness patch failed: %v", err)
		}
		if _, _, err := DeletePodForUpdate(ctx, r, cloud, updated, false, logr.Discard()); err != nil {
			t.Fatalf("real pod delete failed: %v", err)
		}
		if err := c.Get(ctx, client.ObjectKeyFromObject(updated), &corev1.Pod{}); !apierrors.IsNotFound(err) {
			t.Fatalf("pod still exists after delete: %v", err)
		}

		replacement := candidate.DeepCopy()
		replacement.UID = types.UID("replacement-uid")
		replacement.ResourceVersion = ""
		if err := c.Create(ctx, replacement); err != nil {
			t.Fatal(err)
		}
		mustRecord(t, "StatefulSetRecreatePod", speculatrace.Args{Pod: speculatrace.UpdatePod})
		// The first real CLUSTERSTATUS response is also the consumer contract
		// used by this bounded external recovery observation.
		mustRecord(t, "SolrRecoverReplica", speculatrace.Args{Replica: speculatrace.NRTReplica})
		mustRecord(t, "SolrElectLeader", speculatrace.Args{Shard: speculatrace.TargetShard, Replica: speculatrace.NRTReplica})
	})
}

type balanceSolr struct {
	mu         sync.Mutex
	state      string
	checkError bool
	submitErr  bool
}

func (s *balanceSolr) transport(req *http.Request) (*http.Response, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if req.URL.Query().Get("action") == "REQUESTSTATUS" {
		if s.checkError {
			return nil, errors.New("injected REQUESTSTATUS transport failure")
		}
		return jsonResponse(fmt.Sprintf(`{"responseHeader":{"status":0},"status":{"state":%q}}`, s.state)), nil
	}
	if req.Method == http.MethodPost && req.URL.Path == "/api/cluster/replicas/balance" {
		if s.submitErr {
			return nil, errors.New("injected balance submission failure")
		}
		s.state = "running"
		return jsonResponse(`{"responseHeader":{"status":0},"requestId":"balance-replicas-trace"}`), nil
	}
	if req.URL.Query().Get("action") == "DELETESTATUS" {
		s.state = "notfound"
		return jsonResponse(`{"responseHeader":{"status":0},"status":"success"}`), nil
	}
	return nil, fmt.Errorf("unexpected request: %s", req.URL.String())
}

func startOp(t *testing.T, op string) {
	if op == "rolling" {
		mustRecord(t, "StartRollingClusterOp")
	} else {
		mustRecord(t, "StartBalanceClusterOp")
	}
	mustRecord(t, "ControllerRuntimeDeliverClusterOpEvent", speculatrace.Args{Op: op})
}

func TestTraceClusterOperationsThroughSolrAPI(t *testing.T) {
	cloud := boundedCloud()
	sts := &appsv1.StatefulSet{Spec: appsv1.StatefulSetSpec{Replicas: pointer.Int32(2)}, Status: appsv1.StatefulSetStatus{ReadyReplicas: 2}}

	traceScenario(t, "cluster-balance-success", "OP", func(_ string) {
		server := &balanceSolr{state: "notfound"}
		solr_api.SetNoVerifyTLSHttpClient(&http.Client{Transport: roundTripFunc(server.transport)})
		startOp(t, "balance")
		complete, inProgress, retry, err := util.BalanceReplicasForCluster(context.Background(), cloud, sts, "trace", "trace", logr.Discard())
		if err != nil || complete || !inProgress || retry != 5*time.Second {
			t.Fatalf("unexpected real submit result complete=%v inProgress=%v retry=%s err=%v", complete, inProgress, retry, err)
		}
		mustRecord(t, "SolrCloudReconcileClusterOpDispatcher", speculatrace.Args{Op: "balance"})
		server.mu.Lock()
		server.state = "completed"
		server.mu.Unlock()
		mustRecord(t, "SolrBalanceReplicasTaskCompletes")
		mustRecord(t, "ControllerTimerFires", speculatrace.Args{Op: "balance"})
		mustRecord(t, "ControllerRuntimeDeliverClusterOpEvent", speculatrace.Args{Op: "balance"})
		complete, inProgress, _, err = util.BalanceReplicasForCluster(context.Background(), cloud, sts, "trace", "trace", logr.Discard())
		if err != nil || !complete || inProgress {
			t.Fatalf("unexpected real completion result complete=%v inProgress=%v err=%v", complete, inProgress, err)
		}
		mustRecord(t, "SolrCloudReconcileClusterOpDispatcher", speculatrace.Args{Op: "balance"})
	})

	traceScenario(t, "cluster-balance-check-failure", "OP", func(_ string) {
		server := &balanceSolr{state: "notfound", checkError: true}
		solr_api.SetNoVerifyTLSHttpClient(&http.Client{Transport: roundTripFunc(server.transport)})
		startOp(t, "balance")
		_, inProgress, retry, err := util.BalanceReplicasForCluster(context.Background(), cloud, sts, "trace", "trace", logr.Discard())
		if err == nil || inProgress || retry != 0 {
			t.Fatalf("REQUESTSTATUS failure was not observed faithfully: inProgress=%v retry=%s err=%v", inProgress, retry, err)
		}
		mustRecord(t, "SolrCloudReconcileClusterOpDispatcher", speculatrace.Args{Op: "balance"})
	})

	traceScenario(t, "cluster-balance-submit-failure", "OP", func(_ string) {
		server := &balanceSolr{state: "notfound", submitErr: true}
		solr_api.SetNoVerifyTLSHttpClient(&http.Client{Transport: roundTripFunc(server.transport)})
		startOp(t, "balance")
		_, inProgress, retry, err := util.BalanceReplicasForCluster(context.Background(), cloud, sts, "trace", "trace", logr.Discard())
		if err == nil || inProgress || retry != 0 {
			t.Fatalf("submit failure was not observed faithfully: inProgress=%v retry=%s err=%v", inProgress, retry, err)
		}
		mustRecord(t, "SolrCloudReconcileClusterOpDispatcher", speculatrace.Args{Op: "balance"})
	})
}

func TestTraceRollingOperationBoundaries(t *testing.T) {
	cloud := boundedCloud()
	sts := &appsv1.StatefulSet{Spec: appsv1.StatefulSetSpec{Replicas: pointer.Int32(2)}}
	op := &SolrClusterOp{Operation: UpdateLock, Metadata: `{}`}
	r, _ := newReconciler(traceScheme(t), cloud)

	traceScenario(t, "cluster-rolling-failure", "OP", func(_ string) {
		startOp(t, "rolling")
		solr_api.SetNoVerifyTLSHttpClient(&http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) { return nil, errors.New("injected CLUSTERSTATUS failure") })})
		_, inProgress, retry, _, err := handleManagedCloudRollingUpdate(context.Background(), r, cloud, sts, op, util.OutOfDatePodSegmentation{Running: []corev1.Pod{{ObjectMeta: metav1.ObjectMeta{Name: "trace-solrcloud-0"}}}}, true, 0, logr.Discard())
		if err == nil || !inProgress || retry != 0 {
			t.Fatalf("rolling failure tuple changed: inProgress=%v retry=%s err=%v", inProgress, retry, err)
		}
		mustRecord(t, "HandleManagedCloudRollingUpdateClusterStateFailure")
		mustRecord(t, "SolrCloudReconcileClusterOpDispatcher", speculatrace.Args{Op: "rolling"})
	})

	traceScenario(t, "cluster-rolling-complete", "OP", func(_ string) {
		startOp(t, "rolling")
		complete, _, _, _, err := handleManagedCloudRollingUpdate(context.Background(), r, cloud, sts, op, util.OutOfDatePodSegmentation{}, true, 2, logr.Discard())
		if err != nil || !complete {
			t.Fatalf("rolling completion path failed: complete=%v err=%v", complete, err)
		}
		mustRecord(t, "HandleManagedCloudRollingUpdateComplete")
		mustRecord(t, "SolrCloudReconcileClusterOpDispatcher", speculatrace.Args{Op: "rolling"})
	})
}

type backupSolr struct {
	mu          sync.Mutex
	collections []string
	states      map[string]string
}

func (s *backupSolr) transport(req *http.Request) (*http.Response, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	action := req.URL.Query().Get("action")
	switch action {
	case "LIST":
		data, _ := json.Marshal(s.collections)
		return jsonResponse(fmt.Sprintf(`{"responseHeader":{"status":0},"collections":%s}`, data)), nil
	case "BACKUP":
		id := req.URL.Query().Get("async")
		s.states[id] = "running"
		return jsonResponse(fmt.Sprintf(`{"responseHeader":{"status":0},"requestId":%q}`, id)), nil
	case "REQUESTSTATUS":
		id := req.URL.Query().Get("requestid")
		state, ok := s.states[id]
		if !ok {
			state = "notfound"
		}
		return jsonResponse(fmt.Sprintf(`{"responseHeader":{"status":0},"status":{"state":%q}}`, state)), nil
	case "DELETESTATUS":
		delete(s.states, req.URL.Query().Get("requestid"))
		return jsonResponse(`{"responseHeader":{"status":0},"status":"success"}`), nil
	default:
		return nil, fmt.Errorf("unexpected backup request %s", req.URL.String())
	}
}

func backupObjects() (*solrv1beta1.SolrCloud, *solrv1beta1.SolrBackup, *solrv1beta1.SolrBackupRepository) {
	cloud := boundedCloud()
	repo := solrv1beta1.SolrBackupRepository{Name: "repo", S3: &solrv1beta1.S3Repository{Bucket: "bucket", Region: "region"}}
	cloud.Spec.BackupRepositories = []solrv1beta1.SolrBackupRepository{repo}
	cloud.Status.BackupRepositoriesAvailable = map[string]bool{"repo": true}
	backup := &solrv1beta1.SolrBackup{ObjectMeta: metav1.ObjectMeta{Name: "trace-backup", Namespace: "default"}, Spec: solrv1beta1.SolrBackupSpec{SolrCloud: cloud.Name, RepositoryName: "repo"}}
	return cloud, backup, &repo
}

func TestTraceBackupRealSolrLifecycle(t *testing.T) {
	cloud, backup, repo := backupObjects()
	server := &backupSolr{collections: []string{speculatrace.CollectionA, speculatrace.CollectionB}, states: map[string]string{}}
	solr_api.SetNoVerifyTLSHttpClient(&http.Client{Transport: roundTripFunc(server.transport)})

	traceScenario(t, "backup-cleanup-order", "BK", func(_ string) {
		status := &solrv1beta1.IndividualSolrBackupStatus{StartTime: metav1.Now()}
		mustRecord(t, "StartBackupRun")
		for _, collection := range []string{speculatrace.CollectionA, speculatrace.CollectionB} {
			finished, err := reconcileSolrCollectionBackup(context.Background(), backup, status, cloud, repo, collection, logr.Discard())
			if err != nil || finished {
				t.Fatalf("real BACKUP submit failed for %s: finished=%v err=%v", collection, finished, err)
			}
		}
		server.mu.Lock()
		for requestID := range server.states {
			server.states[requestID] = "completed"
		}
		server.mu.Unlock()
		for _, collection := range []string{speculatrace.CollectionA, speculatrace.CollectionB} {
			mustRecord(t, "SolrBackupTaskCompletes", speculatrace.Args{Collection: collection})
			finished, err := reconcileSolrCollectionBackup(context.Background(), backup, status, cloud, repo, collection, logr.Discard())
			if err != nil || !finished {
				t.Fatalf("real REQUESTSTATUS/DELETESTATUS failed for %s: finished=%v err=%v", collection, finished, err)
			}
		}
		if !util.UpdateStatusOfCollectionBackups(status) {
			t.Fatal("real aggregate status did not become terminal")
		}
		mustRecord(t, "PatchSolrBackupStatus")
		if _, err := util.ScheduleNextBackup("*/5 * * * *", status.StartTime.Time); err != nil {
			t.Fatal(err)
		}
	})

	traceScenario(t, "backup-cohort-change", "BK", func(_ string) {
		mustRecord(t, "StartBackupRun")
		server.mu.Lock()
		server.collections = []string{speculatrace.CollectionA}
		server.mu.Unlock()
		mustRecord(t, "DeleteCollectionDuringBackup", speculatrace.Args{Collection: speculatrace.CollectionB})
		collections, err := util.ListAllSolrCollections(context.Background(), cloud, logr.Discard())
		if err != nil || len(collections) != 1 {
			t.Fatalf("real LIST after delete failed: %v %v", collections, err)
		}
		server.mu.Lock()
		server.collections = []string{speculatrace.CollectionA, speculatrace.CollectionB}
		server.mu.Unlock()
		mustRecord(t, "AddCollectionDuringBackup", speculatrace.Args{Collection: speculatrace.CollectionB})
		collections, err = util.ListAllSolrCollections(context.Background(), cloud, logr.Discard())
		if err != nil || len(collections) != 2 {
			t.Fatalf("real LIST after add failed: %v %v", collections, err)
		}
	})

	traceScenario(t, "backup-async-record-loss", "BK", func(_ string) {
		status := &solrv1beta1.IndividualSolrBackupStatus{StartTime: metav1.Now()}
		mustRecord(t, "StartBackupRun")
		if _, err := reconcileSolrCollectionBackup(context.Background(), backup, status, cloud, repo, speculatrace.CollectionA, logr.Discard()); err != nil {
			t.Fatal(err)
		}
		server.mu.Lock()
		delete(server.states, util.AsyncIdForCollectionBackup(speculatrace.CollectionA, backup.Name))
		server.mu.Unlock()
		finished, err := reconcileSolrCollectionBackup(context.Background(), backup, status, cloud, repo, speculatrace.CollectionA, logr.Discard())
		if err != nil || finished {
			t.Fatalf("real REQUESTSTATUS=notfound contract changed: finished=%v err=%v", finished, err)
		}
	})

	traceScenario(t, "backup-status-patch-conflict", "BK", func(_ string) {
		status := &solrv1beta1.IndividualSolrBackupStatus{StartTime: metav1.Now()}
		mustRecord(t, "StartBackupRun")
		if _, err := reconcileSolrCollectionBackup(context.Background(), backup, status, cloud, repo, speculatrace.CollectionA, logr.Discard()); err != nil {
			t.Fatal(err)
		}
		server.mu.Lock()
		server.states[util.AsyncIdForCollectionBackup(speculatrace.CollectionA, backup.Name)] = "completed"
		server.mu.Unlock()
		mustRecord(t, "SolrBackupTaskCompletes", speculatrace.Args{Collection: speculatrace.CollectionA})
		if _, err := reconcileSolrCollectionBackup(context.Background(), backup, status, cloud, repo, speculatrace.CollectionA, logr.Discard()); err != nil {
			t.Fatal(err)
		}
		conflictClient := fake.NewClientBuilder().WithScheme(traceScheme(t)).WithObjects(backup.DeepCopy()).WithStatusSubresource(&solrv1beta1.SolrBackup{}).WithInterceptorFuncs(interceptor.Funcs{
			SubResourcePatch: func(_ context.Context, _ client.Client, _ string, _ client.Object, _ client.Patch, _ ...client.SubResourcePatchOption) error {
				return apierrors.NewConflict(schema.GroupResource{Group: "solr.apache.org", Resource: "solrbackups"}, backup.Name, errors.New("injected status conflict"))
			},
		}).Build()
		mutated := backup.DeepCopy()
		mutated.Status.IndividualSolrBackupStatus = *status
		if err := conflictClient.Status().Patch(context.Background(), mutated, client.MergeFrom(backup.DeepCopy())); !apierrors.IsConflict(err) {
			t.Fatalf("expected real status writer conflict, got %v", err)
		}
		mustRecord(t, "PatchSolrBackupStatusConflict")
	})
}

type failNthCreateClient struct {
	client.Client
	mu      sync.Mutex
	creates int
	failAt  int
}

func (c *failNthCreateClient) Create(ctx context.Context, obj client.Object, opts ...client.CreateOption) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.creates++
	if c.creates == c.failAt {
		return apierrors.NewServiceUnavailable("injected Secret create failure")
	}
	return c.Client.Create(ctx, obj, opts...)
}

func authCloud() *solrv1beta1.SolrCloud {
	cloud := boundedCloud()
	cloud.Spec.SolrSecurity = &solrv1beta1.SolrSecurityOptions{AuthenticationType: solrv1beta1.Basic}
	cloud.WithDefaults(logr.Discard())
	return cloud
}

func TestTraceBasicAuthRealSecretAndTemplatePaths(t *testing.T) {
	ctx := context.Background()
	scheme := traceScheme(t)

	traceScenario(t, "basic-auth-success", "AU", func(_ string) {
		cloud := authCloud()
		var base client.Client = fake.NewClientBuilder().WithScheme(scheme).WithObjects(cloud).Build()
		mustRecord(t, "RequestBasicAuth")
		security, err := util.ReconcileSecurityConfig(ctx, &base, cloud)
		if err != nil || security == nil || security.SecurityJson == "" {
			t.Fatalf("real security reconciliation failed: %v", err)
		}
		for _, name := range []string{cloud.BasicAuthSecretName(), cloud.SecurityBootstrapSecretName()} {
			if err := base.Get(ctx, types.NamespacedName{Name: name, Namespace: cloud.Namespace}, &corev1.Secret{}); err != nil {
				t.Fatalf("expected generated Secret %s: %v", name, err)
			}
		}
		status := &solrv1beta1.SolrCloudStatus{ZookeeperConnectionInfo: solrv1beta1.ZookeeperConnectionInfo{InternalConnectionString: "zk:2181", ChRoot: "/"}}
		sts := util.GenerateStatefulSet(cloud, status, nil, map[string]string{}, nil, security)
		if len(sts.Spec.Template.Spec.InitContainers) == 0 {
			t.Fatal("real StatefulSet omitted setup-zk")
		}
		if err := base.Create(ctx, sts); err != nil {
			t.Fatal(err)
		}
		mustRecord(t, "ApplySecurityStatefulSet")
		mustRecord(t, "RunSetupZKSecurityJson")
		mustRecord(t, "KubernetesAuthPodBecomesReady")
		mustRecord(t, "CreateCloudStatus")
	})

	traceScenario(t, "basic-auth-create-failure-recovery", "AU", func(_ string) {
		cloud := authCloud()
		var base client.Client = fake.NewClientBuilder().WithScheme(scheme).WithObjects(cloud).Build()
		failing := client.Client(&failNthCreateClient{Client: base, failAt: 2})
		mustRecord(t, "RequestBasicAuth")
		if _, err := util.ReconcileSecurityConfig(ctx, &failing, cloud); err == nil {
			t.Fatal("second real Secret create unexpectedly succeeded")
		}
		if err := base.Get(ctx, types.NamespacedName{Name: cloud.BasicAuthSecretName(), Namespace: cloud.Namespace}, &corev1.Secret{}); err != nil {
			t.Fatalf("first Secret was not durable: %v", err)
		}
		mustRecord(t, "ControllerRuntimeRetryBasicAuth")
		security, err := util.ReconcileSecurityConfig(ctx, &base, cloud)
		if err != nil || security == nil || security.SecurityJson != "" {
			t.Fatalf("existing-secret tolerant path changed: security=%+v err=%v", security, err)
		}
		status := &solrv1beta1.SolrCloudStatus{ZookeeperConnectionInfo: solrv1beta1.ZookeeperConnectionInfo{InternalConnectionString: "zk:2181", ChRoot: "/"}}
		sts := util.GenerateStatefulSet(cloud, status, nil, map[string]string{}, nil, security)
		if err := base.Create(ctx, sts); err != nil {
			t.Fatal(err)
		}
		mustRecord(t, "ApplySecurityStatefulSet")
		mustRecord(t, "KubernetesAuthPodBecomesReady")
		mustRecord(t, "CreateCloudStatus")
	})

	traceScenario(t, "basic-auth-manual-repair", "AU", func(_ string) {
		cloud := authCloud()
		var base client.Client = fake.NewClientBuilder().WithScheme(scheme).WithObjects(cloud).Build()
		failing := client.Client(&failNthCreateClient{Client: base, failAt: 2})
		mustRecord(t, "RequestBasicAuth")
		_, _ = util.ReconcileSecurityConfig(ctx, &failing, cloud)
		mustRecord(t, "ControllerRuntimeRetryBasicAuth")
		manual := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: cloud.SecurityBootstrapSecretName(), Namespace: cloud.Namespace}, Data: map[string][]byte{util.SecurityJsonFile: []byte(`{"authentication":{}}`)}}
		if err := base.Create(ctx, manual); err != nil {
			t.Fatal(err)
		}
		mustRecord(t, "ManualCreateBootstrapSecret")
		security, err := util.ReconcileSecurityConfig(ctx, &base, cloud)
		if err != nil || security.SecurityJson == "" {
			t.Fatalf("manual bootstrap Secret was not consumed: %v", err)
		}
		_ = util.GenerateStatefulSet(cloud, &solrv1beta1.SolrCloudStatus{ZookeeperConnectionInfo: solrv1beta1.ZookeeperConnectionInfo{InternalConnectionString: "zk:2181", ChRoot: "/"}}, nil, map[string]string{}, nil, security)
		mustRecord(t, "ApplySecurityStatefulSet")
		mustRecord(t, "RunSetupZKSecurityJson")
		mustRecord(t, "KubernetesAuthPodBecomesReady")
		mustRecord(t, "CreateCloudStatus")
		mustRecord(t, "ExternalModifyZKSecurity")
	})
}
