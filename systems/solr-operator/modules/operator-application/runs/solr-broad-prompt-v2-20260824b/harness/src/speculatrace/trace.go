// Licensed to the Apache Software Foundation (ASF) under one or more
// contributor license agreements. See the NOTICE file distributed with this
// work for additional information regarding copyright ownership.
// The ASF licenses this file to You under the Apache License, Version 2.0.

// Package speculatrace is a test-only observation sink for the Solr Operator
// trace harness. It keeps only the bounded identity mappings and ghost fields
// required by Trace.tla. Calls are no-ops unless Start has enabled a trace.
package speculatrace

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"sync"
	"time"
)

const (
	UpdatePod   = "update-pod"
	PullPod     = "pull-pod"
	NRTReplica  = "nrt-replica"
	PullReplica = "pull-replica"
	TargetShard = "collection1|shard1"
	CollectionA = "collection-a"
	CollectionB = "collection-b"
)

type Args struct {
	Pod        string
	Replica    string
	Shard      string
	Op         string
	Collection string
	Selected   bool
}

type managedUpdateState struct {
	ReplicaType          map[string]string `json:"replicaType"`
	ReplicaState         map[string]string `json:"replicaState"`
	ReplicaNode          map[string]string `json:"replicaNode"`
	Leader               map[string]string `json:"leader"`
	PodRevision          map[string]string `json:"podRevision"`
	PodReady             map[string]bool   `json:"podReady"`
	PodExists            map[string]bool   `json:"podExists"`
	ScheduledForDeletion []string          `json:"scheduledForDeletion"`
	ClusterSnapshot      snapshot          `json:"clusterSnapshot"`
	SnapshotValid        bool              `json:"snapshotValid"`
	SelectedForUpdate    []string          `json:"selectedForUpdate"`
	SelectionPending     bool              `json:"selectionPending"`
}

type snapshot struct {
	ReplicaState map[string]string `json:"replicaState"`
	ReplicaNode  map[string]string `json:"replicaNode"`
	PodReady     map[string]bool   `json:"podReady"`
	PodExists    map[string]bool   `json:"podExists"`
}

type clusterOpState struct {
	ClusterOpLock            []string          `json:"clusterOpLock"`
	OpQueue                  []string          `json:"opQueue"`
	OpStatus                 map[string]string `json:"opStatus"`
	OpError                  map[string]bool   `json:"opError"`
	AsyncState               map[string]string `json:"asyncState"`
	RetryDue                 []string          `json:"retryDue"`
	EventDue                 []string          `json:"eventDue"`
	DispatchReady            []string          `json:"dispatchReady"`
	HandlerReturned          []string          `json:"handlerReturned"`
	HandlerRequestInProgress []string          `json:"handlerRequestInProgress"`
	BalanceReadyToSubmit     []string          `json:"balanceReadyToSubmit"`
	OpAge                    map[string]int    `json:"opAge"`
}

type backupState struct {
	AvailableCollections []string          `json:"availableCollections"`
	BackupActive         bool              `json:"backupActive"`
	BackupCohort         []string          `json:"backupCohort"`
	InitialBackupCohort  []string          `json:"initialBackupCohort"`
	WorkingCRStatus      map[string]string `json:"workingCRStatus"`
	DurableCRStatus      map[string]string `json:"durableCRStatus"`
	TaskState            map[string]string `json:"taskState"`
	TaskRecord           map[string]bool   `json:"taskRecord"`
	TaskEverSubmitted    map[string]bool   `json:"taskEverSubmitted"`
	CleanupPending       []string          `json:"cleanupPending"`
	BackupFinished       bool              `json:"backupFinished"`
	NextScheduled        bool              `json:"nextScheduled"`
	BackupListNeeded     bool              `json:"backupListNeeded"`
	StatusPatchPending   bool              `json:"statusPatchPending"`
}

type basicAuthState struct {
	BasicAuthRequested      bool   `json:"basicAuthRequested"`
	AuthPhase               string `json:"authPhase"`
	AuthSecret              bool   `json:"authSecret"`
	BootstrapSecret         bool   `json:"bootstrapSecret"`
	CredentialVersion       string `json:"credentialVersion"`
	BootstrapVersion        string `json:"bootstrapVersion"`
	SecurityJSONLoaded      bool   `json:"securityJsonLoaded"`
	PodTemplateHasBootstrap bool   `json:"podTemplateHasBootstrap"`
	PodTemplateApplied      bool   `json:"podTemplateApplied"`
	PodCredentialVersion    string `json:"podCredentialVersion"`
	ZKSecurityVersion       string `json:"zkSecurityVersion"`
	AuthPodReady            bool   `json:"authPodReady"`
	CloudReady              bool   `json:"cloudReady"`
}

type traceEvent struct {
	Tag        string `json:"tag"`
	TS         string `json:"ts"`
	Event      string `json:"event"`
	Pod        string `json:"pod,omitempty"`
	Replica    string `json:"replica,omitempty"`
	Shard      string `json:"shard,omitempty"`
	Op         string `json:"op,omitempty"`
	Collection string `json:"collection,omitempty"`
	After      any    `json:"after"`
}

type recorder struct {
	mu     sync.Mutex
	file   *os.File
	writer *bufio.Writer
	family string
	muS    managedUpdateState
	opS    clusterOpState
	bkS    backupState
	auS    basicAuthState
}

var global recorder

func Start(path, family string) error {
	global.mu.Lock()
	defer global.mu.Unlock()
	if global.file != nil {
		return errors.New("a Specula trace is already active")
	}
	if family != "MU" && family != "OP" && family != "BK" && family != "AU" {
		return fmt.Errorf("unknown trace family %q", family)
	}
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	global.file = file
	global.writer = bufio.NewWriter(file)
	global.family = family
	global.muS = initialManagedUpdate()
	global.opS = initialClusterOp()
	global.bkS = initialBackup()
	global.auS = initialBasicAuth()
	return nil
}

func Close() error {
	global.mu.Lock()
	defer global.mu.Unlock()
	if global.file == nil {
		return nil
	}
	flushErr := global.writer.Flush()
	closeErr := global.file.Close()
	global.file, global.writer, global.family = nil, nil, ""
	if flushErr != nil {
		return flushErr
	}
	return closeErr
}

func Active() bool {
	global.mu.Lock()
	defer global.mu.Unlock()
	return global.file != nil
}

// Record records a completed real-code or consumer-observation boundary.
// The bounded state update uses only the outcome supplied by the call site;
// it never drives the operator or decides whether an operation succeeded.
func Record(event string, args Args) error {
	global.mu.Lock()
	defer global.mu.Unlock()
	if global.file == nil {
		return nil
	}
	if err := global.apply(event, args); err != nil {
		return err
	}
	after, err := global.after()
	if err != nil {
		return err
	}
	record := traceEvent{Tag: "trace", TS: time.Now().UTC().Format(time.RFC3339Nano), Event: event, Pod: args.Pod, Replica: args.Replica, Shard: args.Shard, Op: args.Op, Collection: args.Collection, After: after}
	if err = json.NewEncoder(global.writer).Encode(record); err != nil {
		return err
	}
	return global.writer.Flush()
}

func (r *recorder) after() (any, error) {
	switch r.family {
	case "MU":
		sort.Strings(r.muS.ScheduledForDeletion)
		sort.Strings(r.muS.SelectedForUpdate)
		return r.muS, nil
	case "OP":
		sortOpSets(&r.opS)
		return r.opS, nil
	case "BK":
		sort.Strings(r.bkS.AvailableCollections)
		sort.Strings(r.bkS.BackupCohort)
		sort.Strings(r.bkS.InitialBackupCohort)
		sort.Strings(r.bkS.CleanupPending)
		return r.bkS, nil
	case "AU":
		return r.auS, nil
	default:
		return nil, fmt.Errorf("no active family")
	}
}

func (r *recorder) apply(event string, a Args) error {
	switch r.family {
	case "MU":
		return applyMU(&r.muS, event, a)
	case "OP":
		return applyOP(&r.opS, event, a)
	case "BK":
		return applyBK(&r.bkS, event, a)
	case "AU":
		return applyAU(&r.auS, event)
	}
	return fmt.Errorf("no active trace family")
}

func initialManagedUpdate() managedUpdateState {
	replicaState := map[string]string{NRTReplica: "active", PullReplica: "active"}
	replicaNode := map[string]string{NRTReplica: UpdatePod, PullReplica: PullPod}
	podReady := map[string]bool{UpdatePod: true, PullPod: true}
	podExists := map[string]bool{UpdatePod: true, PullPod: true}
	return managedUpdateState{
		ReplicaType: map[string]string{NRTReplica: "NRT", PullReplica: "PULL"}, ReplicaState: replicaState,
		ReplicaNode: replicaNode, Leader: map[string]string{TargetShard: NRTReplica},
		PodRevision: map[string]string{UpdatePod: "old", PullPod: "new"}, PodReady: podReady, PodExists: podExists,
		ScheduledForDeletion: []string{}, SelectedForUpdate: []string{},
		ClusterSnapshot: snapshot{ReplicaState: cloneStringMap(replicaState), ReplicaNode: cloneStringMap(replicaNode), PodReady: cloneBoolMap(podReady), PodExists: cloneBoolMap(podExists)},
	}
}

func initialClusterOp() clusterOpState {
	return clusterOpState{ClusterOpLock: []string{}, OpQueue: []string{}, OpStatus: map[string]string{"rolling": "idle", "balance": "idle"}, OpError: map[string]bool{"rolling": false, "balance": false}, AsyncState: map[string]string{"rolling": "none", "balance": "none"}, RetryDue: []string{}, EventDue: []string{}, DispatchReady: []string{}, HandlerReturned: []string{}, HandlerRequestInProgress: []string{}, BalanceReadyToSubmit: []string{}, OpAge: map[string]int{"rolling": 0, "balance": 0}}
}

func initialBackup() backupState {
	return backupState{AvailableCollections: []string{CollectionA, CollectionB}, BackupCohort: []string{}, InitialBackupCohort: []string{}, WorkingCRStatus: map[string]string{CollectionA: "absent", CollectionB: "absent"}, DurableCRStatus: map[string]string{CollectionA: "absent", CollectionB: "absent"}, TaskState: map[string]string{CollectionA: "none", CollectionB: "none"}, TaskRecord: map[string]bool{CollectionA: false, CollectionB: false}, TaskEverSubmitted: map[string]bool{CollectionA: false, CollectionB: false}, CleanupPending: []string{}}
}

func initialBasicAuth() basicAuthState {
	return basicAuthState{AuthPhase: "idle", CredentialVersion: "none", BootstrapVersion: "none", PodCredentialVersion: "none", ZKSecurityVersion: "none"}
}

func applyMU(s *managedUpdateState, event string, a Args) error {
	switch event {
	case "StartManagedUpdate":
		s.SelectionPending, s.SnapshotValid, s.SelectedForUpdate = true, false, []string{}
	case "GetNodeReplicaState":
		s.ClusterSnapshot = snapshot{ReplicaState: cloneStringMap(s.ReplicaState), ReplicaNode: cloneStringMap(s.ReplicaNode), PodReady: cloneBoolMap(s.PodReady), PodExists: cloneBoolMap(s.PodExists)}
		s.SnapshotValid = true
	case "DeterminePodsSafeToUpdate":
		if a.Selected {
			s.SelectedForUpdate = add(s.SelectedForUpdate, a.Pod)
		}
		s.SelectionPending = false
	case "EnsurePodReadinessConditions":
		s.PodReady[a.Pod] = false
		s.ScheduledForDeletion = add(s.ScheduledForDeletion, a.Pod)
	case "DeletePodForUpdate":
		s.PodExists[a.Pod] = false
		for replica, pod := range s.ReplicaNode {
			if pod == a.Pod {
				s.ReplicaState[replica] = "down"
				if s.Leader[TargetShard] == replica {
					s.Leader[TargetShard] = "NO_REPLICA"
				}
			}
		}
	case "StatefulSetRecreatePod":
		s.PodExists[a.Pod], s.PodReady[a.Pod], s.PodRevision[a.Pod] = true, false, "new"
		s.ScheduledForDeletion = remove(s.ScheduledForDeletion, a.Pod)
		for replica, pod := range s.ReplicaNode {
			if pod == a.Pod {
				s.ReplicaState[replica] = "recovering"
			}
		}
	case "SolrRecoverReplica":
		s.ReplicaState[a.Replica] = "active"
		s.PodReady[s.ReplicaNode[a.Replica]] = true
	case "SolrElectLeader":
		s.Leader[a.Shard] = a.Replica
	default:
		return fmt.Errorf("event %q is not in MU", event)
	}
	return nil
}

func applyOP(s *clusterOpState, event string, a Args) error {
	op := a.Op
	if op == "" {
		if event == "StartRollingClusterOp" || event == "HandleManagedCloudRollingUpdateClusterStateFailure" || event == "HandleManagedCloudRollingUpdateComplete" {
			op = "rolling"
		} else {
			op = "balance"
		}
	}
	switch event {
	case "StartRollingClusterOp", "StartBalanceClusterOp":
		s.ClusterOpLock, s.OpStatus[op], s.EventDue, s.OpAge[op] = []string{op}, "nonterminal", add(s.EventDue, op), 0
	case "ControllerRuntimeDeliverClusterOpEvent":
		s.EventDue, s.DispatchReady = remove(s.EventDue, op), add(s.DispatchReady, op)
	case "HandleManagedCloudRollingUpdateClusterStateFailure":
		s.DispatchReady, s.HandlerReturned, s.HandlerRequestInProgress, s.OpError[op] = remove(s.DispatchReady, op), add(s.HandlerReturned, op), add(s.HandlerRequestInProgress, op), true
	case "HandleManagedCloudRollingUpdateComplete":
		s.DispatchReady, s.HandlerReturned, s.OpStatus[op], s.OpError[op] = remove(s.DispatchReady, op), add(s.HandlerReturned, op), "terminal", false
	case "BalanceReplicasForClusterCheckFailure":
		s.DispatchReady, s.HandlerReturned, s.HandlerRequestInProgress, s.OpError[op] = remove(s.DispatchReady, op), add(s.HandlerReturned, op), remove(s.HandlerRequestInProgress, op), true
	case "BalanceReplicasForClusterNotFound":
		s.DispatchReady, s.BalanceReadyToSubmit = remove(s.DispatchReady, op), add(s.BalanceReadyToSubmit, op)
	case "BalanceReplicasForClusterSubmitFailure":
		s.BalanceReadyToSubmit, s.HandlerReturned, s.HandlerRequestInProgress, s.OpError[op] = remove(s.BalanceReadyToSubmit, op), add(s.HandlerReturned, op), remove(s.HandlerRequestInProgress, op), true
	case "BalanceReplicasForClusterSubmitSuccess":
		s.BalanceReadyToSubmit, s.AsyncState[op], s.RetryDue, s.HandlerReturned, s.HandlerRequestInProgress, s.OpError[op] = remove(s.BalanceReadyToSubmit, op), "running", add(s.RetryDue, op), add(s.HandlerReturned, op), add(s.HandlerRequestInProgress, op), false
	case "SolrBalanceReplicasTaskCompletes":
		s.AsyncState[op] = "completed"
	case "ControllerTimerFires":
		s.RetryDue, s.EventDue = remove(s.RetryDue, op), add(s.EventDue, op)
	case "BalanceReplicasForClusterCompleted":
		s.DispatchReady, s.HandlerReturned, s.HandlerRequestInProgress, s.OpStatus[op], s.AsyncState[op], s.OpError[op] = remove(s.DispatchReady, op), add(s.HandlerReturned, op), remove(s.HandlerRequestInProgress, op), "terminal", "none", false
	case "SolrCloudReconcileClusterOpDispatcher":
		s.OpError[op] = false
		s.HandlerReturned, s.HandlerRequestInProgress = remove(s.HandlerReturned, op), remove(s.HandlerRequestInProgress, op)
		if s.OpStatus[op] == "terminal" {
			s.ClusterOpLock = remove(s.ClusterOpLock, op)
		} else if s.OpAge[op] > 1 {
			s.ClusterOpLock, s.OpQueue, s.EventDue = remove(s.ClusterOpLock, op), add(s.OpQueue, op), add(s.EventDue, op)
		}
	case "RetryNextQueuedClusterOp":
		s.OpQueue, s.ClusterOpLock, s.EventDue = remove(s.OpQueue, op), []string{op}, add(s.EventDue, op)
	default:
		return fmt.Errorf("event %q is not in OP", event)
	}
	return nil
}

func applyBK(s *backupState, event string, a Args) error {
	c := a.Collection
	switch event {
	case "StartBackupRun":
		s.BackupActive, s.BackupCohort, s.InitialBackupCohort, s.StatusPatchPending = true, cloneSlice(s.AvailableCollections), cloneSlice(s.AvailableCollections), true
		s.WorkingCRStatus = map[string]string{CollectionA: "absent", CollectionB: "absent"}
		s.DurableCRStatus = map[string]string{CollectionA: "absent", CollectionB: "absent"}
		s.TaskState = map[string]string{CollectionA: "none", CollectionB: "none"}
		s.TaskRecord = map[string]bool{CollectionA: false, CollectionB: false}
		s.TaskEverSubmitted = map[string]bool{CollectionA: false, CollectionB: false}
		s.CleanupPending, s.BackupFinished, s.NextScheduled, s.BackupListNeeded = []string{}, false, false, false
	case "DeleteCollectionDuringBackup":
		s.AvailableCollections, s.BackupListNeeded = remove(s.AvailableCollections, c), true
	case "AddCollectionDuringBackup":
		s.AvailableCollections, s.BackupListNeeded = add(s.AvailableCollections, c), true
	case "ListAllSolrCollections":
		s.BackupCohort, s.BackupListNeeded = cloneSlice(s.AvailableCollections), false
	case "ReconcileSolrCollectionBackupSubmit":
		s.WorkingCRStatus[c], s.TaskState[c], s.TaskRecord[c], s.TaskEverSubmitted[c], s.StatusPatchPending = "submitted", "running", true, true, true
	case "SolrBackupTaskCompletes":
		s.TaskState[c] = "completed"
	case "CheckAsyncRequestCompleted":
		s.WorkingCRStatus[c], s.CleanupPending, s.StatusPatchPending = "completed", add(s.CleanupPending, c), true
	case "DeleteAsyncRequestForBackup":
		s.TaskRecord[c], s.TaskState[c], s.CleanupPending = false, "none", remove(s.CleanupPending, c)
	case "PatchSolrBackupStatus":
		for collection, status := range s.WorkingCRStatus {
			s.DurableCRStatus[collection] = status
		}
		s.StatusPatchPending = false
	case "PatchSolrBackupStatusConflict":
		for collection, status := range s.DurableCRStatus {
			s.WorkingCRStatus[collection] = status
		}
		s.StatusPatchPending = false
	case "CheckAsyncRequestNotFound":
		// The consumer observed that Solr no longer has the async record. The
		// controller's submitted CR status remains unchanged.
		s.TaskRecord[c], s.TaskState[c] = false, "none"
	case "UpdateStatusOfCollectionBackups":
		seen, allTerminal := false, true
		for _, status := range s.WorkingCRStatus {
			if status != "absent" {
				seen = true
				allTerminal = allTerminal && (status == "completed" || status == "failed")
			}
		}
		s.BackupFinished = seen && allTerminal
		s.StatusPatchPending = s.StatusPatchPending || s.BackupFinished
	case "ScheduleNextBackup":
		s.NextScheduled, s.BackupActive = true, false
	default:
		return fmt.Errorf("event %q is not in BK", event)
	}
	return nil
}

func applyAU(s *basicAuthState, event string) error {
	switch event {
	case "RequestBasicAuth":
		s.BasicAuthRequested, s.AuthPhase = true, "lookup"
	case "ReconcileForBasicAuthLookupMissingSecret":
		s.AuthPhase = "createAuth"
	case "CreateBasicAuthSecret":
		s.AuthSecret, s.CredentialVersion, s.AuthPhase = true, "v1", "createBootstrap"
	case "CreateBootstrapSecret":
		s.BootstrapSecret, s.BootstrapVersion, s.SecurityJSONLoaded, s.AuthPhase = true, s.CredentialVersion, true, "generateTemplate"
	case "FailBootstrapSecretCreate":
		s.AuthPhase = "error"
	case "ControllerRuntimeRetryBasicAuth":
		s.AuthPhase = "lookup"
	case "ReconcileForBasicAuthLookupExistingSecret":
		s.SecurityJSONLoaded = s.BootstrapSecret
		if s.BootstrapSecret {
			s.BootstrapVersion = s.CredentialVersion
		} else {
			s.BootstrapVersion = "none"
		}
		s.AuthPhase = "generateTemplate"
	case "GenerateZKInteractionInitContainer":
		s.PodTemplateHasBootstrap, s.PodCredentialVersion, s.PodTemplateApplied, s.AuthPodReady, s.CloudReady, s.AuthPhase = s.SecurityJSONLoaded, s.CredentialVersion, false, false, false, "applyTemplate"
	case "ApplySecurityStatefulSet":
		s.PodTemplateApplied, s.AuthPhase = true, "idle"
	case "RunSetupZKSecurityJson":
		s.ZKSecurityVersion = s.PodCredentialVersion
	case "KubernetesAuthPodBecomesReady":
		s.AuthPodReady = true
	case "CreateCloudStatus":
		s.CloudReady = s.AuthPodReady
	case "ExternalModifyZKSecurity":
		s.ZKSecurityVersion = "external"
	case "ManualCreateBootstrapSecret":
		s.BootstrapSecret, s.BootstrapVersion, s.AuthPhase = true, s.CredentialVersion, "lookup"
	default:
		return fmt.Errorf("event %q is not in AU", event)
	}
	return nil
}

func add(values []string, value string) []string {
	for _, current := range values {
		if current == value {
			return values
		}
	}
	return append(values, value)
}

func remove(values []string, value string) []string {
	out := make([]string, 0, len(values))
	for _, current := range values {
		if current != value {
			out = append(out, current)
		}
	}
	return out
}

func cloneSlice(values []string) []string { return append([]string{}, values...) }

func cloneStringMap(values map[string]string) map[string]string {
	out := make(map[string]string, len(values))
	for key, value := range values {
		out[key] = value
	}
	return out
}

func cloneBoolMap(values map[string]bool) map[string]bool {
	out := make(map[string]bool, len(values))
	for key, value := range values {
		out[key] = value
	}
	return out
}

func sortOpSets(s *clusterOpState) {
	sets := []*[]string{&s.ClusterOpLock, &s.OpQueue, &s.RetryDue, &s.EventDue, &s.DispatchReady, &s.HandlerReturned, &s.HandlerRequestInProgress, &s.BalanceReadyToSubmit}
	for _, set := range sets {
		sort.Strings(*set)
	}
}
