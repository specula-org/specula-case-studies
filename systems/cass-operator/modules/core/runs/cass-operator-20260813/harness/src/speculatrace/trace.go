package speculatrace

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"sync"
	"time"
)

const (
	NoEpoch               = "none"
	NoJob                 = "none"
	CassOperatorFinalizer = "cassandra.datastax.com/finalizer"
	ForeignFinalizer      = "example.com/foreign-finalizer"
)

type Fields map[string]any

type Event struct {
	Name          string
	Scenario      int
	OperationKind string
	Args          Fields
}

type SnapshotFunc func(Event) (any, error)

type Config struct {
	Path            string
	Scenario        int
	OperationKind   string
	MetadataOutcome string
	Append          bool
	Snapshot        SnapshotFunc
	AfterEmit       func(Event) error
}

type traceSession struct {
	mu       sync.Mutex
	file     *os.File
	encoder  *json.Encoder
	config   Config
	counts   map[string]int
	jobIDs   map[string]string
	eventNum int
}

var active struct {
	sync.RWMutex
	session *traceSession
}

type ResourceState struct {
	ControllerUp        bool   `json:"controller_up"`
	LiveDCEpoch         string `json:"live_dc_epoch"`
	CachedDCEpoch       string `json:"cached_dc_epoch"`
	DeletingDCEpoch     string `json:"deleting_dc_epoch"`
	CachedSTSOwnerEpoch string `json:"cached_sts_owner_epoch"`
	CachedPVCEpoch      string `json:"cached_pvc_epoch"`
	CachedPVCInUse      bool   `json:"cached_pvc_in_use"`
	STSOwnerEpoch       string `json:"sts_owner_epoch"`
	STSReplicas         int    `json:"sts_replicas"`
	PodEpoch            string `json:"pod_epoch"`
	PodExists           bool   `json:"pod_exists"`
	PVCEpoch            string `json:"pvc_epoch"`
	PVCExists           bool   `json:"pvc_exists"`
	PVCInUse            bool   `json:"pvc_in_use"`
	LastMutationActor   string `json:"last_mutation_actor"`
	LastMutationTarget  string `json:"last_mutation_target"`
	LastMutationKind    string `json:"last_mutation_kind"`
}

type DecommissionState struct {
	ControllerUp                 bool   `json:"controller_up"`
	MetadataOutcome              string `json:"metadata_outcome"`
	RingState                    string `json:"ring_state"`
	ObservedRingState            string `json:"observed_ring_state"`
	CleanupTarget                string `json:"cleanup_target"`
	CleanupPhase                 string `json:"cleanup_phase"`
	STSReplicas                  int    `json:"sts_replicas"`
	PodExists                    bool   `json:"pod_exists"`
	PVCExists                    bool   `json:"pvc_exists"`
	NodeStatusExists             bool   `json:"node_status_exists"`
	LoadKnown                    bool   `json:"load_known"`
	CapacityApproved             bool   `json:"capacity_approved"`
	AuthoritativeRemovalObserved bool   `json:"authoritative_removal_observed"`
	CleanupStarted               bool   `json:"cleanup_started"`
}

type OperationState struct {
	ControllerUp          bool     `json:"controller_up"`
	OperationKind         string   `json:"operation_kind"`
	RemoteState           string   `json:"remote_state"`
	RequestAccepted       bool     `json:"request_accepted"`
	DurableMarker         string   `json:"durable_marker"`
	JobID                 string   `json:"job_id"`
	PendingJobID          string   `json:"pending_job_id"`
	RemoteJobs            []string `json:"remote_jobs"`
	StartupPodExists      bool     `json:"startup_pod_exists"`
	StartupLabel          string   `json:"startup_label"`
	StartupReady          bool     `json:"startup_ready"`
	StartupTimestamped    bool     `json:"startup_timestamped"`
	StartupRetryRequested bool     `json:"startup_retry_requested"`
	OccurrenceState       string   `json:"occurrence_state"`
	ScheduleCreatePending bool     `json:"schedule_create_pending"`
	ChildExists           bool     `json:"child_exists"`
	TaskLabel             string   `json:"task_label"`
	TaskStatus            string   `json:"task_status"`
}

type RolloutState struct {
	ControllerUp    bool `json:"controller_up"`
	DesiredSize     int  `json:"desired_size"`
	STSReplicas     int  `json:"sts_replicas"`
	ReadyPods       int  `json:"ready_pods"`
	PDBPresent      bool `json:"pdb_present"`
	PDBMinAvailable int  `json:"pdb_min_available"`
	EvictedPods     int  `json:"evicted_pods"`
}

type DeletionState struct {
	ControllerUp         bool     `json:"controller_up"`
	Deleting             bool     `json:"deleting"`
	DependencyPresent    bool     `json:"dependency_present"`
	DecommissionRequired bool     `json:"decommission_required"`
	MgmtReady            bool     `json:"mgmt_ready"`
	ContextReady         bool     `json:"context_ready"`
	ValidationPassed     bool     `json:"validation_passed"`
	Finalizers           []string `json:"finalizers"`
	OrdinaryCleanupDone  bool     `json:"ordinary_cleanup_done"`
}

func InitialResourceState() ResourceState {
	return ResourceState{
		ControllerUp:        true,
		LiveDCEpoch:         "epoch-a",
		CachedDCEpoch:       "epoch-a",
		DeletingDCEpoch:     NoEpoch,
		CachedSTSOwnerEpoch: NoEpoch,
		CachedPVCEpoch:      NoEpoch,
		CachedPVCInUse:      true,
		STSOwnerEpoch:       "epoch-a",
		STSReplicas:         2,
		PodEpoch:            "epoch-a",
		PodExists:           true,
		PVCEpoch:            "epoch-a",
		PVCExists:           true,
		PVCInUse:            true,
		LastMutationActor:   NoEpoch,
		LastMutationTarget:  NoEpoch,
		LastMutationKind:    "None",
	}
}

func InitialDecommissionState() DecommissionState {
	return DecommissionState{
		ControllerUp:                 true,
		MetadataOutcome:              "Unobserved",
		RingState:                    "Normal",
		ObservedRingState:            "Unknown",
		CleanupTarget:                "None",
		CleanupPhase:                 "Idle",
		STSReplicas:                  2,
		PodExists:                    true,
		PVCExists:                    true,
		NodeStatusExists:             true,
		LoadKnown:                    false,
		CapacityApproved:             false,
		AuthoritativeRemovalObserved: false,
		CleanupStarted:               false,
	}
}

func InitialOperationState(kind string) OperationState {
	return OperationState{
		ControllerUp:          true,
		OperationKind:         kind,
		RemoteState:           "Idle",
		RequestAccepted:       false,
		DurableMarker:         "None",
		JobID:                 NoJob,
		PendingJobID:          NoJob,
		RemoteJobs:            []string{},
		StartupPodExists:      true,
		StartupLabel:          "ReadyToStart",
		StartupReady:          false,
		StartupTimestamped:    false,
		StartupRetryRequested: false,
		OccurrenceState:       "Due",
		ScheduleCreatePending: false,
		ChildExists:           false,
		TaskLabel:             "Pending",
		TaskStatus:            "Pending",
	}
}

func InitialRolloutState() RolloutState {
	return RolloutState{
		ControllerUp:    true,
		DesiredSize:     2,
		STSReplicas:     2,
		ReadyPods:       2,
		PDBPresent:      true,
		PDBMinAvailable: 1,
		EvictedPods:     0,
	}
}

func InitialDeletionState() DeletionState {
	return DeletionState{
		ControllerUp:         true,
		Deleting:             false,
		DependencyPresent:    true,
		DecommissionRequired: false,
		MgmtReady:            false,
		ContextReady:         false,
		ValidationPassed:     false,
		Finalizers:           []string{CassOperatorFinalizer, ForeignFinalizer},
		OrdinaryCleanupDone:  false,
	}
}

func Begin(config Config) error {
	if config.Path == "" {
		return errors.New("trace path is required")
	}
	if config.Scenario < 1 || config.Scenario > 5 {
		return fmt.Errorf("invalid scenario %d", config.Scenario)
	}
	if config.Scenario == 3 {
		if !validOperationKinds[config.OperationKind] {
			return fmt.Errorf("invalid Scenario 3 operation kind %q", config.OperationKind)
		}
	} else {
		config.OperationKind = "None"
	}
	if config.Snapshot == nil {
		return errors.New("snapshot provider is required")
	}

	active.Lock()
	defer active.Unlock()
	if active.session != nil {
		return errors.New("a trace session is already active")
	}

	if err := os.MkdirAll(filepath.Dir(config.Path), 0o755); err != nil {
		return fmt.Errorf("create trace directory: %w", err)
	}
	flags := os.O_CREATE | os.O_WRONLY
	if config.Append {
		flags |= os.O_APPEND
	} else {
		flags |= os.O_TRUNC
	}
	file, err := os.OpenFile(config.Path, flags, 0o644)
	if err != nil {
		return fmt.Errorf("open trace: %w", err)
	}

	active.session = &traceSession{
		file:    file,
		encoder: json.NewEncoder(file),
		config:  config,
		counts:  map[string]int{},
		jobIDs:  map[string]string{},
	}
	return nil
}

func Close() error {
	active.Lock()
	session := active.session
	active.session = nil
	active.Unlock()
	if session == nil {
		return errors.New("no active trace session")
	}

	session.mu.Lock()
	defer session.mu.Unlock()
	var closeErr error
	if session.eventNum == 0 {
		closeErr = errors.New("trace contains no events")
	}
	if err := session.file.Sync(); err != nil {
		closeErr = errors.Join(closeErr, fmt.Errorf("sync trace: %w", err))
	}
	if err := session.file.Close(); err != nil {
		closeErr = errors.Join(closeErr, fmt.Errorf("close trace: %w", err))
	}
	return closeErr
}

func Enabled(scenario int, operationKind string) bool {
	active.RLock()
	session := active.session
	active.RUnlock()
	if session == nil || session.config.Scenario != scenario {
		return false
	}
	return operationKind == "" || session.config.OperationKind == operationKind
}

func MetadataOutcome() string {
	active.RLock()
	defer active.RUnlock()
	if active.session == nil {
		return ""
	}
	return active.session.config.MetadataOutcome
}

func Emit(name string, args Fields) error {
	active.RLock()
	session := active.session
	active.RUnlock()
	if session == nil {
		return nil
	}
	if scenario, ok := eventScenarios[name]; !ok {
		return fmt.Errorf("unknown trace event %q", name)
	} else if scenario != 0 && scenario != session.config.Scenario {
		return nil
	}
	if kind := eventKinds[name]; kind != "" && kind != session.config.OperationKind {
		return nil
	}
	return session.emit(name, args)
}

func MustEmit(name string, args Fields) {
	if err := Emit(name, args); err != nil {
		panic(fmt.Sprintf("specula trace emit %s: %v", name, err))
	}
}

func Count(name string) int {
	active.RLock()
	session := active.session
	active.RUnlock()
	if session == nil {
		return 0
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	return session.counts[name]
}

func Await(name string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		if Count(name) > 0 {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out waiting for trace event %s", name)
		}
		time.Sleep(time.Millisecond)
	}
}

func MustWait(name string) {
	active.RLock()
	session := active.session
	active.RUnlock()
	if session == nil {
		return
	}
	if err := Await(name, 30*time.Second); err != nil {
		panic(err)
	}
}

func (session *traceSession) emit(name string, args Fields) error {
	session.mu.Lock()
	normalizedArgs, err := session.normalizeArgs(name, args)
	if err != nil {
		session.mu.Unlock()
		return err
	}
	event := Event{
		Name:          name,
		Scenario:      session.config.Scenario,
		OperationKind: session.config.OperationKind,
		Args:          normalizedArgs,
	}
	state, err := session.config.Snapshot(event)
	if err != nil {
		session.mu.Unlock()
		return fmt.Errorf("snapshot %s: %w", name, err)
	}
	if err := validateState(session.config.Scenario, state); err != nil {
		session.mu.Unlock()
		return fmt.Errorf("validate %s state: %w", name, err)
	}

	line := struct {
		Tag   string `json:"tag"`
		TS    string `json:"ts"`
		Event struct {
			Name          string `json:"name"`
			Scenario      int    `json:"scenario"`
			OperationKind string `json:"operation_kind"`
			Args          Fields `json:"args"`
			State         any    `json:"state"`
		} `json:"event"`
	}{
		Tag: "trace",
		TS:  strconv.FormatInt(time.Now().UnixNano(), 10),
	}
	line.Event.Name = event.Name
	line.Event.Scenario = event.Scenario
	line.Event.OperationKind = event.OperationKind
	line.Event.Args = event.Args
	line.Event.State = state

	if err := session.encoder.Encode(line); err != nil {
		session.mu.Unlock()
		return fmt.Errorf("encode trace event: %w", err)
	}
	if err := session.file.Sync(); err != nil {
		session.mu.Unlock()
		return fmt.Errorf("sync trace event: %w", err)
	}
	session.eventNum++
	session.counts[name]++
	hook := session.config.AfterEmit
	session.mu.Unlock()

	if hook != nil {
		if err := hook(event); err != nil {
			return fmt.Errorf("after %s hook: %w", name, err)
		}
	}
	return nil
}

func (session *traceSession) normalizeArgs(name string, args Fields) (Fields, error) {
	normalized := Fields{}
	for key, value := range args {
		normalized[key] = value
	}
	if name != "StartPodTaskAsync" && name != "CheckRackCompletion" {
		return normalized, nil
	}

	raw, ok := normalized["job_id"].(string)
	if !ok || raw == "" {
		return nil, fmt.Errorf("%s requires a non-empty string job_id", name)
	}
	jobID, found := session.jobIDs[raw]
	if !found {
		if len(session.jobIDs) >= 2 {
			return nil, fmt.Errorf("trace contains more than two distinct maintenance jobs")
		}
		jobID = fmt.Sprintf("job-%d", len(session.jobIDs)+1)
		session.jobIDs[raw] = jobID
	}
	normalized["job_id"] = jobID
	return normalized, nil
}

func validateState(scenario int, state any) error {
	raw, err := json.Marshal(state)
	if err != nil {
		return err
	}
	var fields map[string]any
	if err := json.Unmarshal(raw, &fields); err != nil {
		return err
	}

	required := requiredStateFields[scenario]
	missing := make([]string, 0)
	for _, field := range required {
		if _, ok := fields[field]; !ok {
			missing = append(missing, field)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("missing fields: %v", missing)
	}
	if len(fields) != len(required) {
		extra := make([]string, 0)
		requiredSet := make(map[string]struct{}, len(required))
		for _, field := range required {
			requiredSet[field] = struct{}{}
		}
		for field := range fields {
			if _, ok := requiredSet[field]; !ok {
				extra = append(extra, field)
			}
		}
		sort.Strings(extra)
		return fmt.Errorf("unexpected fields: %v", extra)
	}
	return nil
}

var validOperationKinds = map[string]bool{
	"Startup":       true,
	"Maintenance":   true,
	"Schedule":      true,
	"TaskLifecycle": true,
}

var eventScenarios = map[string]int{
	"BeginDatacenterDeletionEpochA":                1,
	"DeleteDatacenterObjectEpochA":                 1,
	"CreateSameNameDatacenterEpochB":               1,
	"RefreshDatacenterCache":                       1,
	"GetStatefulSetForRack":                        1,
	"ProcessDeletionScaleStatefulSet":              1,
	"StatefulSetControllerDeleteEpochPod":          1,
	"ProcessDeletionListPVCs":                      1,
	"ProcessDeletionCheckPVCInUse":                 1,
	"ProcessDeletionDeletePVC":                     1,
	"GetCassMetadataEndpointsSuccess":              2,
	"GetCassMetadataEndpointsError":                2,
	"GetCassMetadataEndpointsPartial":              2,
	"GetUsedStorageForPodsKnown":                   2,
	"GetUsedStorageForPodsMissing":                 2,
	"EnsurePodsCanAbsorbDecommData":                2,
	"CallDecommission":                             2,
	"CassandraRingMarkLeaving":                     2,
	"CassandraRingMarkLeft":                        2,
	"CassandraRingRemove":                          2,
	"IsDoneDecommissioning":                        2,
	"RemoveDecommissionedPodFromSts":               2,
	"StatefulSetControllerRemoveDecommissionedPod": 2,
	"DeletePodPvcs":                                2,
	"PatchNodeStatusAfterDecommission":             2,
	"StartCassandra":                               3,
	"LabelServerPodStarting":                       3,
	"PatchLastServerNodeStarted":                   3,
	"CallLifecycleStartEndpointAccepted":           3,
	"CallLifecycleStartEndpointError":              3,
	"DeletePodAfterStartFailure":                   3,
	"CassandraPodBecomesReady":                     3,
	"LabelServerPodStarted":                        3,
	"StartPodTaskAsync":                            3,
	"ProcessRackPatchJobID":                        3,
	"ProcessRackPatchJobIDFailure":                 3,
	"CheckRackCompletion":                          3,
	"ScheduledTaskStatusUpdate":                    3,
	"ScheduledTaskCreateChild":                     3,
	"ScheduledTaskCreateChildFailure":              3,
	"CassandraTaskActivateLabel":                   3,
	"CassandraTaskActivateStatus":                  3,
	"CassandraTaskCompleteLabel":                   3,
	"CassandraTaskCompleteStatus":                  3,
	"ChangeDatacenterSize":                         4,
	"CheckRackScale":                               4,
	"PodBecomesReady":                              4,
	"CheckDcPodDisruptionBudgetDelete":             4,
	"CheckDcPodDisruptionBudgetCreate":             4,
	"AdmitVoluntaryEviction":                       4,
	"SetDecommissionOnDelete":                      5,
	"BeginDatacenterDeletion":                      5,
	"DeleteDependencySecret":                       5,
	"CreateReconciliationContext":                  5,
	"IsValid":                                      5,
	"ProcessDeletionOrdinaryCleanup":               5,
	"ProcessDeletionDecommission":                  5,
	"ProcessDeletionRemoveFinalizers":              5,
	"ControllerCrash":                              0,
	"ControllerRecover":                            0,
}

var eventKinds = map[string]string{
	"StartCassandra":                     "Startup",
	"LabelServerPodStarting":             "Startup",
	"PatchLastServerNodeStarted":         "Startup",
	"CallLifecycleStartEndpointAccepted": "Startup",
	"CallLifecycleStartEndpointError":    "Startup",
	"DeletePodAfterStartFailure":         "Startup",
	"CassandraPodBecomesReady":           "Startup",
	"LabelServerPodStarted":              "Startup",
	"StartPodTaskAsync":                  "Maintenance",
	"ProcessRackPatchJobID":              "Maintenance",
	"ProcessRackPatchJobIDFailure":       "Maintenance",
	"CheckRackCompletion":                "Maintenance",
	"ScheduledTaskStatusUpdate":          "Schedule",
	"ScheduledTaskCreateChild":           "Schedule",
	"ScheduledTaskCreateChildFailure":    "Schedule",
	"CassandraTaskActivateLabel":         "TaskLifecycle",
	"CassandraTaskActivateStatus":        "TaskLifecycle",
	"CassandraTaskCompleteLabel":         "TaskLifecycle",
	"CassandraTaskCompleteStatus":        "TaskLifecycle",
}

var requiredStateFields = map[int][]string{
	1: {
		"controller_up", "live_dc_epoch", "cached_dc_epoch",
		"deleting_dc_epoch", "cached_sts_owner_epoch", "cached_pvc_epoch",
		"cached_pvc_in_use", "sts_owner_epoch", "sts_replicas", "pod_epoch",
		"pod_exists", "pvc_epoch", "pvc_exists", "pvc_in_use",
		"last_mutation_actor", "last_mutation_target", "last_mutation_kind",
	},
	2: {
		"controller_up", "metadata_outcome", "ring_state",
		"observed_ring_state", "cleanup_target", "cleanup_phase",
		"sts_replicas", "pod_exists", "pvc_exists", "node_status_exists",
		"load_known", "capacity_approved", "authoritative_removal_observed",
		"cleanup_started",
	},
	3: {
		"controller_up", "operation_kind", "remote_state", "request_accepted",
		"durable_marker", "job_id", "pending_job_id", "remote_jobs",
		"startup_pod_exists", "startup_label", "startup_ready",
		"startup_timestamped", "startup_retry_requested", "occurrence_state",
		"schedule_create_pending", "child_exists", "task_label", "task_status",
	},
	4: {
		"controller_up", "desired_size", "sts_replicas", "ready_pods",
		"pdb_present", "pdb_min_available", "evicted_pods",
	},
	5: {
		"controller_up", "deleting", "dependency_present",
		"decommission_required", "mgmt_ready", "context_ready",
		"validation_passed", "finalizers", "ordinary_cleanup_done",
	},
}
