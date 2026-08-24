package reconciliation

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/go-logr/logr"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	policyv1 "k8s.io/api/policy/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	record "k8s.io/client-go/tools/events"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	api "github.com/k8ssandra/cass-operator/apis/cassandra/v1beta1"
	"github.com/k8ssandra/cass-operator/internal/speculatrace"
	"github.com/k8ssandra/cass-operator/pkg/dynamicwatch"
	"github.com/k8ssandra/cass-operator/pkg/httphelper"
)

const (
	speculaUIDA = "11111111-1111-1111-1111-111111111111"
	speculaUIDB = "22222222-2222-2222-2222-222222222222"
)

func TestSpeculaTraceScenarios(t *testing.T) {
	if os.Getenv("SPECULA_TRACE_DIR") == "" {
		t.Skip("SPECULA_TRACE_DIR is not set")
	}

	t.Run("scenario1-stale-delete", speculaScenario1StaleDelete)
	t.Run("scenario1-cache-refresh", speculaScenario1CacheRefresh)
	t.Run("scenario2-authoritative-decommission", speculaScenario2AuthoritativeDecommission)
	t.Run("scenario2-metadata-error", speculaScenario2MetadataError)
	t.Run("scenario2-metadata-partial", speculaScenario2MetadataPartial)
	t.Run("scenario2-missing-load", speculaScenario2MissingLoad)
	t.Run("scenario3-startup-success", speculaScenario3StartupSuccess)
	t.Run("scenario3-startup-error", speculaScenario3StartupError)
	t.Run("scenario4-rollout", speculaScenario4Rollout)
	t.Run("scenario5-ordinary-delete", speculaScenario5OrdinaryDelete)
	t.Run("scenario5-decommission-delete", speculaScenario5DecommissionDelete)
	t.Run("scenario5-missing-secret", speculaScenario5MissingSecret)
}

func speculaRunTrace(t *testing.T, name string, config speculatrace.Config, run func()) {
	t.Helper()
	config.Path = filepath.Join(os.Getenv("SPECULA_TRACE_DIR"), name+".ndjson")
	require.NoError(t, speculatrace.Begin(config))
	defer func() {
		require.NoError(t, speculatrace.Close())
	}()
	run()
}

func speculaStringArg(event speculatrace.Event, name string) (string, error) {
	value, ok := event.Args[name].(string)
	if !ok {
		return "", fmt.Errorf("%s.%s is not a string", event.Name, name)
	}
	return value, nil
}

func speculaIntArg(event speculatrace.Event, name string) (int, error) {
	switch value := event.Args[name].(type) {
	case int:
		return value, nil
	case int32:
		return int(value), nil
	case int64:
		return int(value), nil
	case float64:
		return int(value), nil
	default:
		return 0, fmt.Errorf("%s.%s is not an integer", event.Name, name)
	}
}

func speculaBoolArg(event speculatrace.Event, name string) (bool, error) {
	value, ok := event.Args[name].(bool)
	if !ok {
		return false, fmt.Errorf("%s.%s is not a boolean", event.Name, name)
	}
	return value, nil
}

func speculaEpoch(uid string) string {
	switch uid {
	case speculaUIDA:
		return "epoch-a"
	case speculaUIDB:
		return "epoch-b"
	default:
		return speculatrace.NoEpoch
	}
}

type speculaResourceTracker struct {
	state speculatrace.ResourceState
}

func newSpeculaResourceTracker() *speculaResourceTracker {
	return &speculaResourceTracker{state: speculatrace.InitialResourceState()}
}

func (tracker *speculaResourceTracker) snapshot(event speculatrace.Event) (any, error) {
	switch event.Name {
	case "BeginDatacenterDeletionEpochA":
		uid, err := speculaStringArg(event, "dc_uid")
		if err != nil {
			return nil, err
		}
		tracker.state.DeletingDCEpoch = speculaEpoch(uid)
		tracker.state.CachedDCEpoch = speculaEpoch(uid)
	case "DeleteDatacenterObjectEpochA":
		tracker.state.LiveDCEpoch = speculatrace.NoEpoch
	case "CreateSameNameDatacenterEpochB":
		tracker.state.LiveDCEpoch = "epoch-b"
		tracker.state.STSOwnerEpoch = "epoch-b"
		tracker.state.STSReplicas = 2
		tracker.state.PodEpoch = "epoch-b"
		tracker.state.PodExists = true
		tracker.state.PVCEpoch = "epoch-b"
		tracker.state.PVCExists = true
		tracker.state.PVCInUse = true
		tracker.state.CachedSTSOwnerEpoch = speculatrace.NoEpoch
		tracker.state.CachedPVCEpoch = speculatrace.NoEpoch
	case "RefreshDatacenterCache":
		uid, err := speculaStringArg(event, "dc_uid")
		if err != nil {
			return nil, err
		}
		tracker.state.CachedDCEpoch = speculaEpoch(uid)
	case "GetStatefulSetForRack":
		uid, err := speculaStringArg(event, "owner_uid")
		if err != nil {
			return nil, err
		}
		tracker.state.CachedSTSOwnerEpoch = speculaEpoch(uid)
	case "ProcessDeletionScaleStatefulSet":
		actorUID, err := speculaStringArg(event, "actor_uid")
		if err != nil {
			return nil, err
		}
		ownerUID, err := speculaStringArg(event, "owner_uid")
		if err != nil {
			return nil, err
		}
		replicas, err := speculaIntArg(event, "replicas")
		if err != nil {
			return nil, err
		}
		tracker.state.STSReplicas = replicas
		tracker.state.LastMutationActor = speculaEpoch(actorUID)
		tracker.state.LastMutationTarget = speculaEpoch(ownerUID)
		tracker.state.LastMutationKind = "StatefulSet"
	case "StatefulSetControllerDeleteEpochPod":
		tracker.state.PodExists = false
		tracker.state.PVCInUse = false
		tracker.state.LastMutationTarget = tracker.state.PodEpoch
		tracker.state.LastMutationKind = "Pod"
	case "ProcessDeletionListPVCs":
		uid, err := speculaStringArg(event, "pvc_uid")
		if err != nil {
			return nil, err
		}
		tracker.state.CachedPVCEpoch = speculaEpoch(uid)
	case "ProcessDeletionCheckPVCInUse":
		inUse, err := speculaBoolArg(event, "in_use")
		if err != nil {
			return nil, err
		}
		tracker.state.CachedPVCInUse = inUse
	case "ProcessDeletionDeletePVC":
		uid, err := speculaStringArg(event, "pvc_uid")
		if err != nil {
			return nil, err
		}
		tracker.state.PVCExists = false
		tracker.state.LastMutationActor = tracker.state.CachedDCEpoch
		tracker.state.LastMutationTarget = speculaEpoch(uid)
		tracker.state.LastMutationKind = "PVC"
	default:
		return nil, fmt.Errorf("unexpected Scenario 1 event %s", event.Name)
	}
	return tracker.state, nil
}

type speculaReplacementFixture struct {
	rc          *ReconciliationContext
	client      client.Client
	replacement *api.CassandraDatacenter
	sts         *appsv1.StatefulSet
	pod         *corev1.Pod
	pvc         *corev1.PersistentVolumeClaim
}

func speculaBuildReplacement(t *testing.T) *speculaReplacementFixture {
	t.Helper()
	template := CreateMockReconciliationContext(logr.Discard())
	oldDC := template.Datacenter.DeepCopy()
	oldDC.UID = types.UID(speculaUIDA)
	oldDC.Finalizers = []string{api.Finalizer}

	scheme := setupScheme()
	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithStatusSubresource(oldDC).
		WithRuntimeObjects(oldDC).
		WithIndex(&corev1.Pod{}, podPVCClaimNameField, podPVCClaimNames).
		Build()
	require.NoError(t, fakeClient.Delete(context.Background(), oldDC))
	deletingDC := &api.CassandraDatacenter{}
	require.NoError(t, fakeClient.Get(
		context.Background(),
		client.ObjectKeyFromObject(oldDC),
		deletingDC,
	))
	request := &reconcile.Request{NamespacedName: client.ObjectKeyFromObject(oldDC)}
	rc, err := CreateReconciliationContext(
		context.Background(),
		request,
		fakeClient,
		scheme,
		record.NewFakeRecorder(32),
		dynamicwatch.NewDynamicSecretWatches(fakeClient),
		template.ImageRegistry,
		false,
	)
	require.NoError(t, err)
	staleDatacenter := rc.Datacenter.DeepCopy()

	deletingDC.Finalizers = nil
	require.NoError(t, fakeClient.Update(context.Background(), deletingDC))
	require.True(t, apierrors.IsNotFound(fakeClient.Get(
		context.Background(),
		client.ObjectKeyFromObject(oldDC),
		&api.CassandraDatacenter{},
	)))
	speculatrace.MustEmit("DeleteDatacenterObjectEpochA", nil)

	replacement := deletingDC.DeepCopy()
	replacement.ResourceVersion = ""
	replacement.UID = types.UID(speculaUIDB)
	replacement.DeletionTimestamp = nil
	replacement.Finalizers = nil
	replacement.CreationTimestamp = metav1.Now()
	require.NoError(t, fakeClient.Create(context.Background(), replacement))

	sts, err := newStatefulSetForCassandraDatacenter(
		nil,
		"default",
		replacement,
		2,
		template.ImageRegistry,
	)
	require.NoError(t, err)
	sts.UID = types.UID(speculaUIDB)
	require.NoError(t, controllerutil.SetControllerReference(replacement, sts, scheme))
	require.NoError(t, fakeClient.Create(context.Background(), sts))

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      sts.Name + "-1",
			Namespace: replacement.Namespace,
			UID:       types.UID(speculaUIDB),
			Labels:    replacement.GetRackLabels("default"),
		},
		Spec: corev1.PodSpec{
			Volumes: []corev1.Volume{{
				Name: "server-data",
				VolumeSource: corev1.VolumeSource{
					PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{
						ClaimName: "server-data-replacement",
					},
				},
			}},
		},
	}
	require.NoError(t, controllerutil.SetControllerReference(sts, pod, scheme))
	require.NoError(t, fakeClient.Create(context.Background(), pod))

	pvc := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "server-data-replacement",
			Namespace: replacement.Namespace,
			UID:       types.UID(speculaUIDB),
			Labels:    replacement.GetDatacenterLabels(),
		},
	}
	require.NoError(t, controllerutil.SetControllerReference(replacement, pvc, scheme))
	require.NoError(t, fakeClient.Create(context.Background(), pvc))

	speculatrace.MustEmit("CreateSameNameDatacenterEpochB", speculatrace.Fields{
		"dc_uid":  speculaUIDB,
		"sts_uid": speculaUIDB,
		"pod_uid": speculaUIDB,
		"pvc_uid": speculaUIDB,
	})
	rc.Datacenter = staleDatacenter
	return &speculaReplacementFixture{
		rc:          rc,
		client:      fakeClient,
		replacement: replacement,
		sts:         sts,
		pod:         pod,
		pvc:         pvc,
	}
}

func speculaScenario1StaleDelete(t *testing.T) {
	tracker := newSpeculaResourceTracker()
	speculaRunTrace(t, "scenario1-stale-delete", speculatrace.Config{
		Scenario: 1,
		Snapshot: tracker.snapshot,
	}, func() {
		fixture := speculaBuildReplacement(t)
		sts, found, err := fixture.rc.GetStatefulSetForRack(&RackInformation{
			RackName:  "default",
			NodeCount: 2,
		})
		require.NoError(t, err)
		require.True(t, found)
		require.NoError(t, fixture.rc.UpdateRackNodeCount(sts, 0))

		require.NoError(t, fixture.client.Delete(context.Background(), fixture.pod))
		speculatrace.MustEmit("StatefulSetControllerDeleteEpochPod", speculatrace.Fields{
			"pod_uid": speculaUIDB,
		})

		require.NoError(t, fixture.rc.deletePVCs())
		require.True(t, apierrors.IsNotFound(fixture.client.Get(
			context.Background(),
			client.ObjectKeyFromObject(fixture.pvc),
			&corev1.PersistentVolumeClaim{},
		)))
	})
}

func speculaScenario1CacheRefresh(t *testing.T) {
	tracker := newSpeculaResourceTracker()
	speculaRunTrace(t, "scenario1-cache-refresh", speculatrace.Config{
		Scenario: 1,
		Snapshot: tracker.snapshot,
	}, func() {
		fixture := speculaBuildReplacement(t)
		request := &reconcile.Request{NamespacedName: client.ObjectKeyFromObject(fixture.replacement)}
		_, err := CreateReconciliationContext(
			context.Background(),
			request,
			fixture.client,
			setupScheme(),
			record.NewFakeRecorder(16),
			dynamicwatch.NewDynamicSecretWatches(fixture.client),
			fixture.rc.ImageRegistry,
			false,
		)
		require.NoError(t, err)
	})
}

type speculaDecommissionTracker struct {
	state speculatrace.DecommissionState
}

func newSpeculaDecommissionTracker() *speculaDecommissionTracker {
	return &speculaDecommissionTracker{state: speculatrace.InitialDecommissionState()}
}

func (tracker *speculaDecommissionTracker) snapshot(event speculatrace.Event) (any, error) {
	switch event.Name {
	case "GetCassMetadataEndpointsSuccess":
		tracker.state.MetadataOutcome = "Success"
		tracker.state.ObservedRingState = tracker.state.RingState
	case "GetCassMetadataEndpointsError":
		tracker.state.MetadataOutcome = "Error"
		tracker.state.ObservedRingState = "Absent"
	case "GetCassMetadataEndpointsPartial":
		tracker.state.MetadataOutcome = "Partial"
		tracker.state.ObservedRingState = "Absent"
	case "GetUsedStorageForPodsKnown":
		tracker.state.LoadKnown = true
	case "GetUsedStorageForPodsMissing":
		tracker.state.LoadKnown = false
	case "EnsurePodsCanAbsorbDecommData":
		tracker.state.CapacityApproved = true
	case "CallDecommission":
		tracker.state.CleanupTarget = "target-pod"
		tracker.state.CleanupPhase = "DecommissionSubmitted"
		tracker.state.CleanupStarted = true
	case "CassandraRingMarkLeaving":
		tracker.state.RingState = "Leaving"
	case "CassandraRingMarkLeft":
		tracker.state.RingState = "Left"
	case "CassandraRingRemove":
		tracker.state.RingState = "Absent"
	case "IsDoneDecommissioning":
		tracker.state.CleanupPhase = "CleanupAuthorized"
		tracker.state.AuthoritativeRemovalObserved =
			tracker.state.MetadataOutcome == "Success" &&
				(tracker.state.ObservedRingState == "Left" ||
					tracker.state.ObservedRingState == "Absent")
	case "RemoveDecommissionedPodFromSts":
		replicas, err := speculaIntArg(event, "replicas")
		if err != nil {
			return nil, err
		}
		tracker.state.STSReplicas = replicas
		tracker.state.CleanupPhase = "StatefulSetScaled"
	case "StatefulSetControllerRemoveDecommissionedPod":
		tracker.state.PodExists = false
	case "DeletePodPvcs":
		tracker.state.PVCExists = false
		tracker.state.CleanupPhase = "PVCDeleted"
	case "PatchNodeStatusAfterDecommission":
		tracker.state.NodeStatusExists = false
		tracker.state.CleanupTarget = "None"
		tracker.state.CleanupPhase = "Done"
	default:
		return nil, fmt.Errorf("unexpected Scenario 2 event %s", event.Name)
	}
	return tracker.state, nil
}

type speculaRingFixture struct {
	mu            sync.Mutex
	status        string
	includeTarget bool
	failMetadata  bool
	targetIP      string
	peerIP        string
	targetHostID  string
	peerHostID    string
}

func (ring *speculaRingFixture) endpoints() []httphelper.EndpointState {
	ring.mu.Lock()
	defer ring.mu.Unlock()
	endpoints := []httphelper.EndpointState{{
		RpcAddress: ring.peerIP,
		EndpointIP: ring.peerIP,
		HostID:     ring.peerHostID,
		Status:     string(httphelper.StatusNormal),
		IsAlive:    "true",
		Load:       "5",
	}}
	if ring.includeTarget {
		endpoints = append(endpoints, httphelper.EndpointState{
			RpcAddress: ring.targetIP,
			EndpointIP: ring.targetIP,
			HostID:     ring.targetHostID,
			Status:     ring.status,
			IsAlive:    "true",
			Load:       "10",
		})
	}
	return endpoints
}

func (ring *speculaRingFixture) set(status string, includeTarget bool) {
	ring.mu.Lock()
	defer ring.mu.Unlock()
	ring.status = status
	ring.includeTarget = includeTarget
}

type speculaDecommissionFixture struct {
	rc     *ReconciliationContext
	target *corev1.Pod
	peer   *corev1.Pod
	sts    *appsv1.StatefulSet
	pvc    *corev1.PersistentVolumeClaim
	ring   *speculaRingFixture
}

func speculaNewDecommissionFixture(t *testing.T) *speculaDecommissionFixture {
	t.Helper()
	rc, _, cleanup := setupTest()
	t.Cleanup(cleanup)
	rc.Datacenter.UID = types.UID(speculaUIDA)
	rc.Datacenter.SetCondition(api.DatacenterCondition{
		Type:   api.DatacenterScalingDown,
		Status: corev1.ConditionTrue,
	})
	targetHostID := "target-host"
	peerHostID := "peer-host"
	rc.Datacenter.Status.NodeStatuses = api.CassandraStatusMap{}

	ring := &speculaRingFixture{
		status:        string(httphelper.StatusNormal),
		includeTarget: true,
		targetHostID:  targetHostID,
		peerHostID:    peerHostID,
	}
	server := newFakeMgmtApiServer(t, http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api/v0/metadata/versions/features":
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"cassandra_version":"4.1","features":["async_sstable_tasks"]}`)
		case "/api/v0/metadata/endpoints":
			ring.mu.Lock()
			fail := ring.failMetadata
			ring.mu.Unlock()
			if fail {
				http.Error(w, "metadata unavailable", http.StatusInternalServerError)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(httphelper.CassMetadataEndpoints{Entity: ring.endpoints()})
		case "/api/v1/ops/node/decommission":
			w.WriteHeader(http.StatusOK)
			_, _ = io.WriteString(w, "remote-decommission-job")
		default:
			http.NotFound(w, request)
		}
	}))

	target := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "trace-rack-sts-1",
			Namespace: rc.Datacenter.Namespace,
			Labels: map[string]string{
				api.RackLabel:     "default",
				api.CassNodeState: stateStarted,
			},
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{{Name: "cassandra"}},
			Volumes: []corev1.Volume{{
				Name: "server-data",
				VolumeSource: corev1.VolumeSource{
					PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{
						ClaimName: "server-data-trace-rack-sts-1",
					},
				},
			}},
		},
		Status: corev1.PodStatus{
			ContainerStatuses: []corev1.ContainerStatus{{
				Name:  "cassandra",
				Ready: true,
				State: corev1.ContainerState{
					Running: &corev1.ContainerStateRunning{
						StartedAt: metav1.NewTime(time.Now().Add(-time.Minute)),
					},
				},
			}},
		},
	}
	peer := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "trace-rack-sts-0",
			Namespace: rc.Datacenter.Namespace,
			Labels: map[string]string{
				api.RackLabel:     "default",
				api.CassNodeState: stateStarted,
			},
		},
		Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "cassandra"}}},
		Status: corev1.PodStatus{
			ContainerStatuses: []corev1.ContainerStatus{{Name: "cassandra", Ready: true}},
		},
	}
	server.attachToPod(t, target)
	peer.Status.PodIP = "127.0.0.2"
	ring.targetIP = target.Status.PodIP
	ring.peerIP = peer.Status.PodIP
	rc.Datacenter.Status.NodeStatuses[target.Name] = api.CassandraNodeStatus{
		HostID: targetHostID,
		IP:     target.Status.PodIP,
		Rack:   "default",
	}

	replicas := int32(2)
	sts := &appsv1.StatefulSet{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "trace-rack-sts",
			Namespace: rc.Datacenter.Namespace,
			Labels:    map[string]string{api.RackLabel: "default"},
		},
		Spec: appsv1.StatefulSetSpec{Replicas: &replicas},
	}
	targetPVC := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "server-data-trace-rack-sts-1",
			Namespace: rc.Datacenter.Namespace,
			UID:       "target-pvc",
		},
	}
	peerPVC := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "server-data-trace-rack-sts-0",
			Namespace: rc.Datacenter.Namespace,
		},
		Status: corev1.PersistentVolumeClaimStatus{
			Capacity: corev1.ResourceList{
				corev1.ResourceStorage: resource.MustParse("100"),
			},
		},
	}
	rc.Client = fake.NewClientBuilder().
		WithScheme(setupScheme()).
		WithStatusSubresource(rc.Datacenter, targetPVC, peerPVC).
		WithRuntimeObjects(rc.Datacenter, sts, target, peer, targetPVC, peerPVC).
		WithIndex(&corev1.Pod{}, podPVCClaimNameField, podPVCClaimNames).
		Build()
	rc.NodeMgmtClient = server.client(rc.ReqLogger)
	rc.dcPods = []*corev1.Pod{target, peer}
	rc.clusterPods = []*corev1.Pod{target}
	rc.statefulSets = []*appsv1.StatefulSet{sts}
	return &speculaDecommissionFixture{
		rc:     rc,
		target: target,
		peer:   peer,
		sts:    sts,
		pvc:    targetPVC,
		ring:   ring,
	}
}

func speculaScenario2AuthoritativeDecommission(t *testing.T) {
	fixture := speculaNewDecommissionFixture(t)
	tracker := newSpeculaDecommissionTracker()
	speculaRunTrace(t, "scenario2-authoritative-decommission", speculatrace.Config{
		Scenario:        2,
		MetadataOutcome: "Success",
		Snapshot:        tracker.snapshot,
		AfterEmit: func(event speculatrace.Event) error {
			if event.Name != "RemoveDecommissionedPodFromSts" {
				return nil
			}
			livePod := &corev1.Pod{}
			if err := fixture.rc.Client.Get(
				context.Background(),
				client.ObjectKeyFromObject(fixture.target),
				livePod,
			); err != nil {
				return err
			}
			if err := fixture.rc.Client.Delete(context.Background(), livePod); err != nil {
				return err
			}
			return speculatrace.Emit("StatefulSetControllerRemoveDecommissionedPod", speculatrace.Fields{
				"pod": fixture.target.Name,
			})
		},
	}, func() {
		endpoints := fixture.rc.getCassMetadataEndpoints()
		require.Len(t, endpoints.Entity, 2)
		require.NoError(t, fixture.rc.DecommissionNodeOnRack("default", endpoints, "sts-1"))

		fixture.ring.set(string(httphelper.StatusLeaving), true)
		speculatrace.MustEmit("CassandraRingMarkLeaving", nil)
		fixture.ring.set(string(httphelper.StatusLeft), true)
		speculatrace.MustEmit("CassandraRingMarkLeft", nil)
		fixture.ring.set("", false)
		speculatrace.MustEmit("CassandraRingRemove", nil)

		endpoints = fixture.rc.getCassMetadataEndpoints()
		require.Len(t, endpoints.Entity, 1)
		fixture.rc.CheckDecommissioningNodes(endpoints)

		require.True(t, apierrors.IsNotFound(fixture.rc.Client.Get(
			context.Background(),
			client.ObjectKeyFromObject(fixture.pvc),
			&corev1.PersistentVolumeClaim{},
		)))
		require.NotContains(t, fixture.rc.Datacenter.Status.NodeStatuses, fixture.target.Name)
	})
}

func speculaScenario2MetadataError(t *testing.T) {
	fixture := speculaNewDecommissionFixture(t)
	fixture.ring.mu.Lock()
	fixture.ring.failMetadata = true
	fixture.ring.mu.Unlock()
	fixture.rc.clusterPods = []*corev1.Pod{fixture.target}
	tracker := newSpeculaDecommissionTracker()
	speculaRunTrace(t, "scenario2-metadata-error", speculatrace.Config{
		Scenario: 2,
		Snapshot: tracker.snapshot,
	}, func() {
		endpoints := fixture.rc.getCassMetadataEndpoints()
		require.Empty(t, endpoints.Entity)
	})
}

func speculaScenario2MetadataPartial(t *testing.T) {
	fixture := speculaNewDecommissionFixture(t)
	fixture.ring.set(string(httphelper.StatusNormal), false)
	fixture.rc.clusterPods = []*corev1.Pod{fixture.target}
	tracker := newSpeculaDecommissionTracker()
	speculaRunTrace(t, "scenario2-metadata-partial", speculatrace.Config{
		Scenario:        2,
		MetadataOutcome: "Partial",
		Snapshot:        tracker.snapshot,
	}, func() {
		endpoints := fixture.rc.getCassMetadataEndpoints()
		require.Len(t, endpoints.Entity, 1)
	})
}

func speculaScenario2MissingLoad(t *testing.T) {
	fixture := speculaNewDecommissionFixture(t)
	tracker := newSpeculaDecommissionTracker()
	speculaRunTrace(t, "scenario2-missing-load", speculatrace.Config{
		Scenario: 2,
		Snapshot: tracker.snapshot,
	}, func() {
		endpoints := httphelper.CassMetadataEndpoints{Entity: []httphelper.EndpointState{{
			RpcAddress: fixture.peer.Status.PodIP,
			Status:     string(httphelper.StatusNormal),
			Load:       "5",
		}}}
		require.NoError(t, fixture.rc.EnsurePodsCanAbsorbDecommData(fixture.target, endpoints))
	})
}

type speculaStartupTracker struct {
	state speculatrace.OperationState
}

func newSpeculaStartupTracker() *speculaStartupTracker {
	return &speculaStartupTracker{state: speculatrace.InitialOperationState("Startup")}
}

func (tracker *speculaStartupTracker) snapshot(event speculatrace.Event) (any, error) {
	switch event.Name {
	case "StartCassandra":
		tracker.state.RemoteState = "InFlight"
	case "LabelServerPodStarting":
		tracker.state.StartupLabel = "Starting"
		tracker.state.DurableMarker = "StartupStarting"
	case "PatchLastServerNodeStarted":
		tracker.state.StartupTimestamped = true
		tracker.state.DurableMarker = "StartupStartingTimestamp"
	case "CallLifecycleStartEndpointAccepted":
		tracker.state.RemoteState = "Accepted"
		tracker.state.RequestAccepted = true
	case "CallLifecycleStartEndpointError":
		tracker.state.RemoteState = "Failed"
	case "DeletePodAfterStartFailure":
		tracker.state.StartupPodExists = false
		tracker.state.StartupLabel = "Deleted"
	case "CassandraPodBecomesReady":
		tracker.state.StartupReady = true
	case "LabelServerPodStarted":
		tracker.state.StartupLabel = "Started"
		tracker.state.DurableMarker = "StartupStarted"
	default:
		return nil, fmt.Errorf("unexpected Startup event %s", event.Name)
	}
	return tracker.state, nil
}

func speculaNewStartupContext(t *testing.T, status int) (*ReconciliationContext, *corev1.Pod) {
	t.Helper()
	rc, _, cleanup := setupTest()
	t.Cleanup(cleanup)
	server := newFakeMgmtApiServer(t, http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/api/v0/lifecycle/start" {
			http.NotFound(w, request)
			return
		}
		if err := speculatrace.Await("PatchLastServerNodeStarted", 5*time.Second); err != nil {
			http.Error(w, err.Error(), http.StatusGatewayTimeout)
			return
		}
		w.WriteHeader(status)
		_, _ = io.WriteString(w, "OK")
	}))
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "startup-pod",
			Namespace: rc.Datacenter.Namespace,
			Labels: map[string]string{
				api.CassNodeState: stateReadyToStart,
			},
		},
		Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "cassandra"}}},
		Status: corev1.PodStatus{
			ContainerStatuses: []corev1.ContainerStatus{{Name: "cassandra", Ready: false}},
		},
	}
	server.attachToPod(t, pod)
	rc.Client = fake.NewClientBuilder().
		WithScheme(setupScheme()).
		WithStatusSubresource(rc.Datacenter, pod).
		WithRuntimeObjects(rc.Datacenter, pod).
		WithIndex(&corev1.Pod{}, podPVCClaimNameField, podPVCClaimNames).
		Build()
	rc.NodeMgmtClient = server.client(rc.ReqLogger)
	return rc, pod
}

func speculaScenario3StartupSuccess(t *testing.T) {
	tracker := newSpeculaStartupTracker()
	speculaRunTrace(t, "scenario3-startup-success", speculatrace.Config{
		Scenario:      3,
		OperationKind: "Startup",
		Snapshot:      tracker.snapshot,
	}, func() {
		rc, pod := speculaNewStartupContext(t, http.StatusCreated)
		require.NoError(t, rc.startCassandra(httphelper.CassMetadataEndpoints{}, pod))
		require.NoError(t, speculatrace.Await("CallLifecycleStartEndpointAccepted", 5*time.Second))

		livePod := &corev1.Pod{}
		require.NoError(t, rc.Client.Get(rc.Ctx, client.ObjectKeyFromObject(pod), livePod))
		livePod.Status.ContainerStatuses = []corev1.ContainerStatus{{Name: "cassandra", Ready: true}}
		require.NoError(t, rc.Client.Status().Update(rc.Ctx, livePod))
		speculatrace.MustEmit("CassandraPodBecomesReady", speculatrace.Fields{"pod": livePod.Name})

		rc.clusterPods = []*corev1.Pod{livePod}
		_, transitioned, err := rc.findStartingNodes()
		require.NoError(t, err)
		require.True(t, transitioned)
	})
}

func speculaScenario3StartupError(t *testing.T) {
	tracker := newSpeculaStartupTracker()
	speculaRunTrace(t, "scenario3-startup-error", speculatrace.Config{
		Scenario:      3,
		OperationKind: "Startup",
		Snapshot:      tracker.snapshot,
	}, func() {
		rc, pod := speculaNewStartupContext(t, http.StatusInternalServerError)
		require.NoError(t, rc.startCassandra(httphelper.CassMetadataEndpoints{}, pod))
		require.NoError(t, speculatrace.Await("DeletePodAfterStartFailure", 5*time.Second))
		require.Eventually(t, func() bool {
			return len(rc.Datacenter.Status.FailedStarts) == 1
		}, 5*time.Second, 10*time.Millisecond)
	})
}

type speculaRolloutTracker struct {
	state speculatrace.RolloutState
}

func newSpeculaRolloutTracker() *speculaRolloutTracker {
	return &speculaRolloutTracker{state: speculatrace.InitialRolloutState()}
}

func (tracker *speculaRolloutTracker) snapshot(event speculatrace.Event) (any, error) {
	switch event.Name {
	case "ChangeDatacenterSize":
		size, err := speculaIntArg(event, "size")
		if err != nil {
			return nil, err
		}
		tracker.state.DesiredSize = size
	case "CheckRackScale":
		replicas, err := speculaIntArg(event, "replicas")
		if err != nil {
			return nil, err
		}
		tracker.state.STSReplicas = replicas
	case "PodBecomesReady":
		tracker.state.ReadyPods++
	case "CheckDcPodDisruptionBudgetDelete":
		tracker.state.PDBPresent = false
	case "CheckDcPodDisruptionBudgetCreate":
		minAvailable, err := speculaIntArg(event, "min_available")
		if err != nil {
			return nil, err
		}
		tracker.state.PDBPresent = true
		tracker.state.PDBMinAvailable = minAvailable
	case "AdmitVoluntaryEviction":
		tracker.state.EvictedPods++
	default:
		return nil, fmt.Errorf("unexpected Scenario 4 event %s", event.Name)
	}
	return tracker.state, nil
}

func speculaScenario4Rollout(t *testing.T) {
	rc, _, cleanup := setupTest()
	defer cleanup()
	sts, err := newStatefulSetForCassandraDatacenter(
		nil,
		"default",
		rc.Datacenter,
		2,
		rc.ImageRegistry,
	)
	require.NoError(t, err)
	oldPDB := newPodDisruptionBudgetForDatacenter(rc.Datacenter)
	pods := []*corev1.Pod{
		{ObjectMeta: metav1.ObjectMeta{Name: "rollout-0", Namespace: rc.Datacenter.Namespace}},
		{ObjectMeta: metav1.ObjectMeta{Name: "rollout-1", Namespace: rc.Datacenter.Namespace}},
	}
	objects := []runtime.Object{rc.Datacenter, sts, oldPDB, pods[0], pods[1]}
	rc.Client = fake.NewClientBuilder().
		WithScheme(setupScheme()).
		WithStatusSubresource(rc.Datacenter, pods[0], pods[1]).
		WithRuntimeObjects(objects...).
		WithIndex(&corev1.Pod{}, podPVCClaimNameField, podPVCClaimNames).
		Build()
	rc.desiredRackInformation = []*RackInformation{{RackName: "default", NodeCount: 3}}
	rc.statefulSets = []*appsv1.StatefulSet{sts}

	tracker := newSpeculaRolloutTracker()
	speculaRunTrace(t, "scenario4-rollout", speculatrace.Config{
		Scenario: 4,
		Snapshot: tracker.snapshot,
		AfterEmit: func(event speculatrace.Event) error {
			if event.Name != "CheckDcPodDisruptionBudgetDelete" {
				return nil
			}
			if err := rc.Client.Delete(context.Background(), pods[0]); err != nil {
				return err
			}
			return speculatrace.Emit("AdmitVoluntaryEviction", speculatrace.Fields{
				"pod": pods[0].Name,
			})
		},
	}, func() {
		rc.Datacenter.Spec.Size = 3
		require.NoError(t, rc.Client.Update(rc.Ctx, rc.Datacenter))
		speculatrace.MustEmit("ChangeDatacenterSize", speculatrace.Fields{"size": 3})
		rc.CheckRackScale()

		newPod := &corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{
				Name:      "rollout-2",
				Namespace: rc.Datacenter.Namespace,
			},
		}
		require.NoError(t, rc.Client.Create(rc.Ctx, newPod))
		newPod.Status.ContainerStatuses = []corev1.ContainerStatus{{Name: "cassandra", Ready: true}}
		require.NoError(t, rc.Client.Status().Update(rc.Ctx, newPod))
		speculatrace.MustEmit("PodBecomesReady", speculatrace.Fields{"pod": newPod.Name})

		rc.CheckDcPodDisruptionBudget()
		pdb := &policyv1.PodDisruptionBudget{}
		require.NoError(t, rc.Client.Get(
			rc.Ctx,
			types.NamespacedName{Name: rc.Datacenter.Name + "-pdb", Namespace: rc.Datacenter.Namespace},
			pdb,
		))
		require.Equal(t, 2, pdb.Spec.MinAvailable.IntValue())
	})
}

type speculaDeletionTracker struct {
	state speculatrace.DeletionState
}

func newSpeculaDeletionTracker() *speculaDeletionTracker {
	return &speculaDeletionTracker{state: speculatrace.InitialDeletionState()}
}

func (tracker *speculaDeletionTracker) snapshot(event speculatrace.Event) (any, error) {
	switch event.Name {
	case "SetDecommissionOnDelete":
		tracker.state.DecommissionRequired = true
	case "BeginDatacenterDeletion":
		tracker.state.Deleting = true
	case "DeleteDependencySecret":
		tracker.state.DependencyPresent = false
		tracker.state.MgmtReady = false
		tracker.state.ContextReady = false
		tracker.state.ValidationPassed = false
	case "CreateReconciliationContext":
		tracker.state.MgmtReady = true
		tracker.state.ContextReady = true
	case "IsValid":
		tracker.state.ValidationPassed = true
	case "ProcessDeletionOrdinaryCleanup", "ProcessDeletionDecommission":
		tracker.state.OrdinaryCleanupDone = true
	case "ProcessDeletionRemoveFinalizers":
		tracker.state.Finalizers = []string{}
	default:
		return nil, fmt.Errorf("unexpected Scenario 5 event %s", event.Name)
	}
	return tracker.state, nil
}

type speculaDeletionFixture struct {
	dc           *api.CassandraDatacenter
	client       client.Client
	scheme       *runtime.Scheme
	image        *ReconciliationContext
	decommission bool
}

func speculaNewDeletionFixture(t *testing.T, decommission bool, withSTS bool) *speculaDeletionFixture {
	t.Helper()
	template := CreateMockReconciliationContext(logr.Discard())
	dc := template.Datacenter.DeepCopy()
	dc.UID = types.UID(speculaUIDA)
	dc.Finalizers = []string{api.Finalizer, speculatrace.ForeignFinalizer}

	objects := []runtime.Object{dc}
	if withSTS {
		sts, err := newStatefulSetForCassandraDatacenter(nil, "default", dc, 2, template.ImageRegistry)
		require.NoError(t, err)
		objects = append(objects, sts)
	}
	pvc := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "deletion-pvc",
			Namespace: dc.Namespace,
			Labels:    dc.GetDatacenterLabels(),
		},
	}
	objects = append(objects, pvc)

	scheme := setupScheme()
	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithStatusSubresource(dc).
		WithRuntimeObjects(objects...).
		WithIndex(&corev1.Pod{}, podPVCClaimNameField, podPVCClaimNames).
		Build()
	return &speculaDeletionFixture{
		dc:           dc,
		client:       fakeClient,
		scheme:       scheme,
		image:        template,
		decommission: decommission,
	}
}

func (fixture *speculaDeletionFixture) beginDeletion(t *testing.T) {
	t.Helper()
	if fixture.decommission {
		if fixture.dc.Annotations == nil {
			fixture.dc.Annotations = map[string]string{}
		}
		fixture.dc.Annotations[api.DecommissionOnDeleteAnnotation] = "true"
		require.NoError(t, fixture.client.Update(context.Background(), fixture.dc))
		speculatrace.MustEmit("SetDecommissionOnDelete", nil)
	}
	require.NoError(t, fixture.client.Delete(context.Background(), fixture.dc))
	deleting := &api.CassandraDatacenter{}
	require.NoError(t, fixture.client.Get(
		context.Background(),
		client.ObjectKeyFromObject(fixture.dc),
		deleting,
	))
	fixture.dc = deleting
	speculatrace.MustEmit("BeginDatacenterDeletion", nil)
}

func (fixture *speculaDeletionFixture) context(t *testing.T) *ReconciliationContext {
	t.Helper()
	request := &reconcile.Request{NamespacedName: client.ObjectKeyFromObject(fixture.dc)}
	rc, err := CreateReconciliationContext(
		context.Background(),
		request,
		fixture.client,
		fixture.scheme,
		record.NewFakeRecorder(32),
		dynamicwatch.NewDynamicSecretWatches(fixture.client),
		fixture.image.ImageRegistry,
		false,
	)
	require.NoError(t, err)
	require.NoError(t, rc.IsValid(rc.Datacenter))
	return rc
}

func speculaScenario5OrdinaryDelete(t *testing.T) {
	tracker := newSpeculaDeletionTracker()
	speculaRunTrace(t, "scenario5-ordinary-delete", speculatrace.Config{
		Scenario: 5,
		Snapshot: tracker.snapshot,
	}, func() {
		fixture := speculaNewDeletionFixture(t, false, true)
		fixture.beginDeletion(t)
		rc := fixture.context(t)
		first := rc.ProcessDeletion()
		require.NotNil(t, first)
		second := rc.ProcessDeletion()
		require.NotNil(t, second)
	})
}

func speculaScenario5DecommissionDelete(t *testing.T) {
	tracker := newSpeculaDeletionTracker()
	speculaRunTrace(t, "scenario5-decommission-delete", speculatrace.Config{
		Scenario: 5,
		Snapshot: tracker.snapshot,
	}, func() {
		fixture := speculaNewDeletionFixture(t, true, false)
		fixture.beginDeletion(t)
		rc := fixture.context(t)
		result := rc.ProcessDeletion()
		require.NotNil(t, result)
	})
}

func speculaScenario5MissingSecret(t *testing.T) {
	tracker := newSpeculaDeletionTracker()
	speculaRunTrace(t, "scenario5-missing-secret", speculatrace.Config{
		Scenario: 5,
		Snapshot: tracker.snapshot,
	}, func() {
		fixture := speculaNewDeletionFixture(t, false, false)
		fixture.beginDeletion(t)
		secret := &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{
				Name:      "management-credentials",
				Namespace: fixture.dc.Namespace,
			},
		}
		require.NoError(t, fixture.client.Create(context.Background(), secret))
		require.NoError(t, fixture.client.Delete(context.Background(), secret))
		require.True(t, apierrors.IsNotFound(fixture.client.Get(
			context.Background(),
			client.ObjectKeyFromObject(secret),
			&corev1.Secret{},
		)))
		speculatrace.MustEmit("DeleteDependencySecret", speculatrace.Fields{
			"secret": secret.Name,
		})
	})
}
