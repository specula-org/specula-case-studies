package control

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/go-logr/logr"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	cassapi "github.com/k8ssandra/cass-operator/apis/cassandra/v1beta1"
	api "github.com/k8ssandra/cass-operator/apis/control/v1alpha1"
	"github.com/k8ssandra/cass-operator/internal/speculatrace"
	"github.com/k8ssandra/cass-operator/pkg/httphelper"
)

func TestSpeculaTraceScenarios(t *testing.T) {
	if os.Getenv("SPECULA_TRACE_DIR") == "" {
		t.Skip("SPECULA_TRACE_DIR is not set")
	}

	t.Run("scenario3-maintenance-success", speculaMaintenanceSuccess)
	t.Run("scenario3-maintenance-crash", speculaMaintenanceCrash)
	t.Run("scenario3-schedule-success", speculaScheduleSuccess)
	t.Run("scenario3-schedule-create-failure", speculaScheduleCreateFailure)
	t.Run("scenario3-task-lifecycle", speculaTaskLifecycle)
}

func TestSpeculaTraceCrashWorker(t *testing.T) {
	switch os.Getenv("SPECULA_CRASH_PHASE") {
	case "pre-crash":
		speculaCrashPreWorker(t)
	case "recover":
		speculaCrashRecoverWorker(t)
	default:
		t.Skip("not a crash worker")
	}
}

func speculaRunControlTrace(t *testing.T, name string, config speculatrace.Config, run func()) {
	t.Helper()
	config.Path = filepath.Join(os.Getenv("SPECULA_TRACE_DIR"), name+".ndjson")
	require.NoError(t, speculatrace.Begin(config))
	defer func() {
		require.NoError(t, speculatrace.Close())
	}()
	run()
}

type speculaOperationTracker struct {
	state speculatrace.OperationState
}

func newSpeculaOperationTracker(kind string) *speculaOperationTracker {
	return &speculaOperationTracker{state: speculatrace.InitialOperationState(kind)}
}

func (tracker *speculaOperationTracker) snapshot(event speculatrace.Event) (any, error) {
	switch event.Name {
	case "StartPodTaskAsync":
		jobID, err := speculaControlStringArg(event, "job_id")
		if err != nil {
			return nil, err
		}
		tracker.state.RemoteJobs = append(tracker.state.RemoteJobs, jobID)
		tracker.state.PendingJobID = jobID
		tracker.state.RemoteState = "Accepted"
		tracker.state.RequestAccepted = true
	case "ProcessRackPatchJobID":
		tracker.state.JobID = tracker.state.PendingJobID
		tracker.state.PendingJobID = speculatrace.NoJob
		tracker.state.DurableMarker = "MaintenanceJobID"
	case "ProcessRackPatchJobIDFailure":
		tracker.state.PendingJobID = speculatrace.NoJob
		tracker.state.RemoteState = "AcceptedUncheckpointed"
	case "CheckRackCompletion":
		jobID, err := speculaControlStringArg(event, "job_id")
		if err != nil {
			return nil, err
		}
		tracker.state.RemoteJobs = speculaRemoveJob(tracker.state.RemoteJobs, jobID)
		tracker.state.RemoteState = "Completed"
	case "ScheduledTaskStatusUpdate":
		tracker.state.OccurrenceState = "Claimed"
		tracker.state.ScheduleCreatePending = true
		tracker.state.DurableMarker = "OccurrenceClaimed"
	case "ScheduledTaskCreateChild":
		tracker.state.ChildExists = true
		tracker.state.OccurrenceState = "Materialized"
		tracker.state.ScheduleCreatePending = false
		tracker.state.DurableMarker = "OccurrenceMaterialized"
	case "ScheduledTaskCreateChildFailure":
		tracker.state.ScheduleCreatePending = false
	case "CassandraTaskActivateLabel":
		tracker.state.TaskLabel = "Active"
		tracker.state.DurableMarker = "TaskActiveLabel"
	case "CassandraTaskActivateStatus":
		tracker.state.TaskStatus = "Running"
		tracker.state.DurableMarker = "TaskActiveStatus"
	case "CassandraTaskCompleteLabel":
		tracker.state.TaskLabel = "Completed"
		tracker.state.DurableMarker = "TaskCompletedLabel"
	case "CassandraTaskCompleteStatus":
		tracker.state.TaskStatus = "Completed"
		tracker.state.DurableMarker = "TaskCompletedStatus"
	case "ControllerCrash":
		tracker.state.ControllerUp = false
		tracker.state.PendingJobID = speculatrace.NoJob
		tracker.state.ScheduleCreatePending = false
		if tracker.state.OperationKind == "Startup" && tracker.state.RemoteState == "InFlight" {
			tracker.state.RemoteState = "Lost"
		}
	case "ControllerRecover":
		tracker.state.ControllerUp = true
	default:
		return nil, fmt.Errorf("unexpected Scenario 3/%s event %s", tracker.state.OperationKind, event.Name)
	}
	return tracker.state, nil
}

func speculaControlStringArg(event speculatrace.Event, name string) (string, error) {
	value, ok := event.Args[name].(string)
	if !ok {
		return "", fmt.Errorf("%s.%s is not a string", event.Name, name)
	}
	return value, nil
}

func speculaRemoveJob(jobs []string, target string) []string {
	result := make([]string, 0, len(jobs))
	for _, job := range jobs {
		if job != target {
			result = append(result, job)
		}
	}
	return result
}

func speculaControlScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	scheme := runtime.NewScheme()
	require.NoError(t, corev1.AddToScheme(scheme))
	require.NoError(t, cassapi.AddToScheme(scheme))
	require.NoError(t, api.AddToScheme(scheme))
	return scheme
}

type speculaHTTPClient struct{}

func (speculaHTTPClient) Do(request *http.Request) (*http.Response, error) {
	var body string
	switch request.URL.Path {
	case "/api/v0/metadata/versions/features":
		body = `{"cassandra_version":"4.1","features":["async_sstable_tasks"]}`
	case "/api/v0/ops/executor/job":
		jobID := request.URL.Query().Get("job_id")
		body = fmt.Sprintf(`{"id":%q,"type":"Cleanup","status":"COMPLETED"}`, jobID)
	default:
		return &http.Response{
			StatusCode: http.StatusNotFound,
			Body:       io.NopCloser(strings.NewReader("not found")),
			Header:     make(http.Header),
		}, nil
	}
	return &http.Response{
		StatusCode: http.StatusOK,
		Body:       io.NopCloser(strings.NewReader(body)),
		Header:     http.Header{"Content-Type": []string{"application/json"}},
	}, nil
}

func speculaMaintenanceObjects(t *testing.T, failPatch bool) (
	*CassandraTaskReconciler,
	*api.CassandraTask,
	corev1.Pod,
	*TaskConfiguration,
	httphelper.NodeMgmtClient,
) {
	t.Helper()
	scheme := speculaControlScheme(t)
	task := &api.CassandraTask{
		ObjectMeta: metav1.ObjectMeta{Name: "maintenance-task", Namespace: "default"},
		Status: api.CassandraTaskStatus{
			PodStatuses: map[string]api.PodProcessingStatus{},
		},
	}
	builder := fake.NewClientBuilder().
		WithScheme(scheme).
		WithStatusSubresource(task).
		WithRuntimeObjects(task)
	if failPatch {
		builder = builder.WithInterceptorFuncs(interceptor.Funcs{
			SubResourcePatch: func(
				_ context.Context,
				_ client.Client,
				subresource string,
				_ client.Object,
				_ client.Patch,
				_ ...client.SubResourcePatchOption,
			) error {
				if subresource == "status" {
					return errors.New("injected status patch failure")
				}
				return nil
			},
		})
	}
	fakeClient := builder.Build()
	liveTask := &api.CassandraTask{}
	require.NoError(t, fakeClient.Get(context.Background(), client.ObjectKeyFromObject(task), liveTask))

	pod := corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "maintenance-pod", Namespace: "default"},
		Spec: corev1.PodSpec{Containers: []corev1.Container{{
			Name: "cassandra",
			Ports: []corev1.ContainerPort{{
				Name:          "mgmt-api-http",
				ContainerPort: 8080,
			}},
		}}},
		Status: corev1.PodStatus{PodIP: "127.0.0.1"},
	}
	config := &TaskConfiguration{
		Job:          api.CommandCleanup,
		AsyncFeature: httphelper.AsyncSSTableTasks,
		AsyncFunc: func(httphelper.NodeMgmtClient, *corev1.Pod, *TaskConfiguration) (string, error) {
			return "remote-maintenance-job", nil
		},
	}
	nodeClient := httphelper.NodeMgmtClient{
		Client:   speculaHTTPClient{},
		Log:      logr.Discard(),
		Protocol: "http",
	}
	return &CassandraTaskReconciler{Client: fakeClient, Scheme: scheme}, liveTask, pod, config, nodeClient
}

func speculaMaintenanceSuccess(t *testing.T) {
	tracker := newSpeculaOperationTracker("Maintenance")
	speculaRunControlTrace(t, "scenario3-maintenance-success", speculatrace.Config{
		Scenario:      3,
		OperationKind: "Maintenance",
		Snapshot:      tracker.snapshot,
	}, func() {
		reconciler, task, pod, config, nodeClient := speculaMaintenanceObjects(t, false)
		_, _, _, _, err := reconciler.processRack(
			context.Background(),
			task,
			[]corev1.Pod{pod},
			config,
			nodeClient,
			1,
		)
		require.NoError(t, err)
		_, _, completed, _, err := reconciler.checkRackCompletion(
			context.Background(),
			task,
			[]corev1.Pod{pod},
			config,
			nodeClient,
		)
		require.NoError(t, err)
		require.Equal(t, 1, completed)
	})
}

func speculaMaintenanceCrash(t *testing.T) {
	tracePath := filepath.Join(os.Getenv("SPECULA_TRACE_DIR"), "scenario3-maintenance-crash.ndjson")
	workDir := t.TempDir()
	preReady := filepath.Join(workDir, "pre.ready")
	recoverReady := filepath.Join(workDir, "recover.ready")
	release := filepath.Join(workDir, "recover.release")

	preOutput := &bytes.Buffer{}
	pre := exec.Command(os.Args[0], "-test.run=^TestSpeculaTraceCrashWorker$", "-test.v")
	pre.Env = append(os.Environ(),
		"SPECULA_CRASH_PHASE=pre-crash",
		"SPECULA_CRASH_TRACE="+tracePath,
		"SPECULA_CRASH_READY="+preReady,
	)
	pre.Stdout = preOutput
	pre.Stderr = preOutput
	require.NoError(t, pre.Start())
	require.NoError(t, speculaWaitForFile(preReady, 10*time.Second))

	tracker := newSpeculaOperationTracker("Maintenance")
	tracker.state.RemoteState = "AcceptedUncheckpointed"
	tracker.state.RequestAccepted = true
	tracker.state.RemoteJobs = []string{"job-1"}
	require.NoError(t, speculatrace.Begin(speculatrace.Config{
		Path:          tracePath,
		Scenario:      3,
		OperationKind: "Maintenance",
		Append:        true,
		Snapshot:      tracker.snapshot,
	}))
	speculatrace.MustEmit("ControllerCrash", nil)
	require.NoError(t, speculatrace.Close())

	require.NoError(t, pre.Process.Kill())
	_ = pre.Wait()

	recoverOutput := &bytes.Buffer{}
	recover := exec.Command(os.Args[0], "-test.run=^TestSpeculaTraceCrashWorker$", "-test.v")
	recover.Env = append(os.Environ(),
		"SPECULA_CRASH_PHASE=recover",
		"SPECULA_CRASH_READY="+recoverReady,
		"SPECULA_CRASH_RELEASE="+release,
	)
	recover.Stdout = recoverOutput
	recover.Stderr = recoverOutput
	require.NoError(t, recover.Start())
	require.NoError(t, speculaWaitForFile(recoverReady, 10*time.Second))

	require.NoError(t, speculatrace.Begin(speculatrace.Config{
		Path:          tracePath,
		Scenario:      3,
		OperationKind: "Maintenance",
		Append:        true,
		Snapshot:      tracker.snapshot,
	}))
	speculatrace.MustEmit("ControllerRecover", nil)
	require.NoError(t, speculatrace.Close())
	require.NoError(t, os.WriteFile(release, []byte("continue"), 0o600))

	done := make(chan error, 1)
	go func() { done <- recover.Wait() }()
	select {
	case err := <-done:
		require.NoError(t, err, recoverOutput.String())
	case <-time.After(10 * time.Second):
		_ = recover.Process.Kill()
		t.Fatalf("recovery worker timed out: %s", recoverOutput.String())
	}
}

func speculaCrashPreWorker(t *testing.T) {
	tracker := newSpeculaOperationTracker("Maintenance")
	require.NoError(t, speculatrace.Begin(speculatrace.Config{
		Path:          os.Getenv("SPECULA_CRASH_TRACE"),
		Scenario:      3,
		OperationKind: "Maintenance",
		Snapshot:      tracker.snapshot,
	}))
	reconciler, task, pod, config, nodeClient := speculaMaintenanceObjects(t, true)
	_, _, _, _, err := reconciler.processRack(
		context.Background(),
		task,
		[]corev1.Pod{pod},
		config,
		nodeClient,
		1,
	)
	require.Error(t, err)
	require.NoError(t, os.WriteFile(os.Getenv("SPECULA_CRASH_READY"), []byte("paused"), 0o600))
	select {}
}

func speculaCrashRecoverWorker(t *testing.T) {
	scheme := speculaControlScheme(t)
	task := &api.CassandraTask{
		ObjectMeta: metav1.ObjectMeta{Name: "maintenance-task", Namespace: "default"},
	}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithRuntimeObjects(task).Build()
	reconciler := &CassandraTaskReconciler{Client: fakeClient, Scheme: scheme}
	if reconciler.Client == nil {
		t.Fatal("replacement reconciler is not ready")
	}
	require.NoError(t, os.WriteFile(os.Getenv("SPECULA_CRASH_READY"), []byte("ready"), 0o600))
	require.NoError(t, speculaWaitForFile(os.Getenv("SPECULA_CRASH_RELEASE"), 30*time.Second))
}

func speculaWaitForFile(path string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		if _, err := os.Stat(path); err == nil {
			return nil
		} else if !os.IsNotExist(err) {
			return err
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out waiting for %s", path)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func speculaScheduledObjects(t *testing.T, failCreate bool) (*ScheduledTaskReconciler, types.NamespacedName) {
	t.Helper()
	scheme := speculaControlScheme(t)
	now := time.Date(2026, 8, 13, 5, 0, 0, 0, time.UTC)
	dc := &cassapi.CassandraDatacenter{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "scheduled-dc",
			Namespace: "default",
			UID:       "scheduled-dc-uid",
		},
	}
	task := &api.ScheduledTask{
		ObjectMeta: metav1.ObjectMeta{
			Name:              "scheduled-trace",
			Namespace:         "default",
			CreationTimestamp: metav1.NewTime(now),
		},
		Spec: api.ScheduledTaskSpec{
			Schedule: "* * * * *",
			TaskDetails: api.TaskDetails{
				Name: "trace",
				CassandraTaskSpec: api.CassandraTaskSpec{
					Datacenter: corev1.ObjectReference{Name: dc.Name, Namespace: dc.Namespace},
					CassandraTaskTemplate: api.CassandraTaskTemplate{
						Jobs: []api.CassandraJob{{Command: api.CommandCleanup}},
					},
				},
			},
		},
	}
	builder := fake.NewClientBuilder().
		WithScheme(scheme).
		WithStatusSubresource(task).
		WithRuntimeObjects(dc, task)
	if failCreate {
		builder = builder.WithInterceptorFuncs(interceptor.Funcs{
			Create: func(
				ctx context.Context,
				base client.WithWatch,
				object client.Object,
				options ...client.CreateOption,
			) error {
				if _, ok := object.(*api.CassandraTask); ok {
					return errors.New("injected CassandraTask create failure")
				}
				return base.Create(ctx, object, options...)
			},
		})
	}
	fakeClient := builder.Build()
	return &ScheduledTaskReconciler{
		Client: fakeClient,
		Scheme: scheme,
		Clock:  &FakeClock{currentTime: now.Add(61 * time.Second)},
		Log:    ctrl.Log.WithName("specula-scheduled-task"),
	}, client.ObjectKeyFromObject(task)
}

func speculaScheduleSuccess(t *testing.T) {
	tracker := newSpeculaOperationTracker("Schedule")
	speculaRunControlTrace(t, "scenario3-schedule-success", speculatrace.Config{
		Scenario:      3,
		OperationKind: "Schedule",
		Snapshot:      tracker.snapshot,
	}, func() {
		reconciler, key := speculaScheduledObjects(t, false)
		_, err := reconciler.Reconcile(context.Background(), reconcile.Request{NamespacedName: key})
		require.NoError(t, err)
		tasks := &api.CassandraTaskList{}
		require.NoError(t, reconciler.List(context.Background(), tasks))
		require.Len(t, tasks.Items, 1)
	})
}

func speculaScheduleCreateFailure(t *testing.T) {
	tracker := newSpeculaOperationTracker("Schedule")
	speculaRunControlTrace(t, "scenario3-schedule-create-failure", speculatrace.Config{
		Scenario:      3,
		OperationKind: "Schedule",
		Snapshot:      tracker.snapshot,
	}, func() {
		reconciler, key := speculaScheduledObjects(t, true)
		_, err := reconciler.Reconcile(context.Background(), reconcile.Request{NamespacedName: key})
		require.Error(t, err)
	})
}

func speculaTaskLifecycle(t *testing.T) {
	tracker := newSpeculaOperationTracker("TaskLifecycle")
	speculaRunControlTrace(t, "scenario3-task-lifecycle", speculatrace.Config{
		Scenario:      3,
		OperationKind: "TaskLifecycle",
		Snapshot:      tracker.snapshot,
	}, func() {
		scheme := speculaControlScheme(t)
		dc := &cassapi.CassandraDatacenter{
			ObjectMeta: metav1.ObjectMeta{Name: "task-dc", Namespace: "default", UID: "task-dc-uid"},
			Spec: cassapi.CassandraDatacenterSpec{
				ClusterName: "trace-cluster",
			},
		}
		task := &api.CassandraTask{
			ObjectMeta: metav1.ObjectMeta{Name: "lifecycle-task", Namespace: "default"},
			Spec: api.CassandraTaskSpec{
				Datacenter: corev1.ObjectReference{Name: dc.Name, Namespace: dc.Namespace},
				CassandraTaskTemplate: api.CassandraTaskTemplate{
					Jobs: []api.CassandraJob{{Command: api.CommandCleanup}},
				},
			},
		}
		fakeClient := fake.NewClientBuilder().
			WithScheme(scheme).
			WithStatusSubresource(task).
			WithRuntimeObjects(dc, task).
			Build()
		reconciler := &CassandraTaskReconciler{Client: fakeClient, Scheme: scheme}
		_, err := reconciler.Reconcile(
			context.Background(),
			reconcile.Request{NamespacedName: client.ObjectKeyFromObject(task)},
		)
		require.NoError(t, err)

		live := &api.CassandraTask{}
		require.NoError(t, fakeClient.Get(context.Background(), client.ObjectKeyFromObject(task), live))
		require.Equal(t, completedTaskLabelValue, live.Labels[taskStatusLabel])
		require.NotNil(t, live.Status.CompletionTime)
	})
}
