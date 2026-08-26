// Reproduces MC-3 through the operator's normal Reconcile entry point and the
// public Kubernetes/Solr API shapes. No controller state is pre-populated and
// no production source is modified. The in-memory API servers are deterministic
// substitutes for Kubernetes and Solr; the real SolrBackup controller is the
// component under test and its persisted CR status is the observable outcome.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	solrv1beta1 "github.com/apache/solr-operator/api/v1beta1"
	"github.com/apache/solr-operator/controllers"
	"github.com/apache/solr-operator/controllers/util/solr_api"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

const (
	namespace   = "default"
	cloudName   = "mc3-cloud"
	backupName  = "mc3-backup"
	collectionA = "collection-a"
	collectionB = "collection-b"
)

type protocolSolr struct {
	mu          sync.Mutex
	collections map[string]bool
	tasks       map[string]string
	listCalls   int
	backupCalls map[string]int
	pollCalls   map[string]int
	deleteCalls map[string]int
}

func newProtocolSolr() *protocolSolr {
	return &protocolSolr{
		collections: map[string]bool{collectionA: true, collectionB: true},
		tasks:       map[string]string{},
		backupCalls: map[string]int{},
		pollCalls:   map[string]int{},
		deleteCalls: map[string]int{},
	}
}

func jsonResponse(body string) *http.Response {
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"application/json"}},
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}

func (s *protocolSolr) RoundTrip(req *http.Request) (*http.Response, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	q := req.URL.Query()
	switch q.Get("action") {
	case "LIST":
		s.listCalls++
		collections := make([]string, 0, len(s.collections))
		for name := range s.collections {
			collections = append(collections, name)
		}
		sort.Strings(collections)
		payload, _ := json.Marshal(collections)
		return jsonResponse(fmt.Sprintf(`{"responseHeader":{"status":0},"collections":%s}`, payload)), nil

	case "BACKUP":
		collection := q.Get("collection")
		if !s.collections[collection] {
			return jsonResponse(`{"responseHeader":{"status":1},"error":{"msg":"collection not found","code":400}}`), nil
		}
		s.backupCalls[collection]++
		requestID := q.Get("async")
		// A small backup may finish before the controller's next five-second
		// poll. Solr retains that completed async status until DELETESTATUS.
		s.tasks[requestID] = "completed"
		return jsonResponse(fmt.Sprintf(`{"responseHeader":{"status":0},"requestId":%q}`, requestID)), nil

	case "REQUESTSTATUS":
		requestID := q.Get("requestid")
		s.pollCalls[requestID]++
		state, ok := s.tasks[requestID]
		if !ok {
			state = "notfound"
		}
		return jsonResponse(fmt.Sprintf(`{"responseHeader":{"status":0},"status":{"state":%q}}`, state)), nil

	case "DELETESTATUS":
		requestID := q.Get("requestid")
		s.deleteCalls[requestID]++
		delete(s.tasks, requestID)
		return jsonResponse(`{"responseHeader":{"status":0},"status":"success"}`), nil

	case "DELETE":
		// This is the normal Solr Collections API DELETE operation. It removes
		// collection membership, not an independently retained async response.
		name := q.Get("name")
		delete(s.collections, name)
		return jsonResponse(fmt.Sprintf(`{"responseHeader":{"status":0},"deleted":%q}`, name)), nil

	default:
		return nil, fmt.Errorf("unexpected Solr request: %s", req.URL.String())
	}
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func getBackup(ctx context.Context, kube client.Client) *solrv1beta1.SolrBackup {
	backup := &solrv1beta1.SolrBackup{}
	must(kube.Get(ctx, types.NamespacedName{Namespace: namespace, Name: backupName}, backup))
	return backup
}

func collectionStatus(backup *solrv1beta1.SolrBackup, name string) solrv1beta1.CollectionBackupStatus {
	for _, status := range backup.Status.CollectionBackupStatuses {
		if status.Collection == name {
			return status
		}
	}
	panic("missing persisted status for " + name)
}

func reconcile(ctx context.Context, r *controllers.SolrBackupReconciler, iteration int) ctrl.Result {
	result, err := r.Reconcile(ctx, ctrl.Request{NamespacedName: types.NamespacedName{Namespace: namespace, Name: backupName}})
	fmt.Printf("RECONCILE_%d requeue=%v requeue_after=%s err=%v\n", iteration, result.Requeue, result.RequeueAfter.Round(time.Millisecond), err)
	must(err)
	return result
}

func main() {
	ctx := context.Background()
	scheme := runtime.NewScheme()
	must(solrv1beta1.AddToScheme(scheme))

	// Create both CRs through the Kubernetes client interface, as a user would.
	kube := fake.NewClientBuilder().WithScheme(scheme).
		WithStatusSubresource(&solrv1beta1.SolrCloud{}, &solrv1beta1.SolrBackup{}).
		Build()

	repository := solrv1beta1.SolrBackupRepository{
		Name: "repo",
		S3: &solrv1beta1.S3Repository{
			Bucket: "bucket",
			Region: "region",
		},
	}
	cloud := &solrv1beta1.SolrCloud{
		ObjectMeta: metav1.ObjectMeta{Name: cloudName, Namespace: namespace},
		Spec: solrv1beta1.SolrCloudSpec{
			BackupRepositories: []solrv1beta1.SolrBackupRepository{repository},
		},
	}
	must(kube.Create(ctx, cloud))
	cloud.Status.Version = "9.7.0"
	cloud.Status.BackupRepositoriesAvailable = map[string]bool{"repo": true}
	must(kube.Status().Update(ctx, cloud))

	backup := &solrv1beta1.SolrBackup{
		ObjectMeta: metav1.ObjectMeta{Name: backupName, Namespace: namespace},
		Spec: solrv1beta1.SolrBackupSpec{
			SolrCloud:      cloudName,
			RepositoryName: "repo",
			// Collections deliberately omitted: this is the documented
			// "back up every available collection" public configuration.
			Recurrence: &solrv1beta1.BackupRecurrence{
				Schedule: "@every 1h",
				MaxSaved: 5,
			},
		},
	}
	must(kube.Create(ctx, backup))

	peer := newProtocolSolr()
	httpClient := &http.Client{Transport: peer}
	solr_api.SetNoVerifyTLSHttpClient(httpClient)

	reconciler := &controllers.SolrBackupReconciler{
		Client:   kube,
		Scheme:   scheme,
		Recorder: record.NewFakeRecorder(100),
	}

	// Reconcile #1 discovers A and B and submits both through BACKUP. The
	// protocol peer completes both quickly, before the next status poll.
	firstResult := reconcile(ctx, reconciler, 1)
	afterSubmit := getBackup(ctx, kube)
	aSubmit := collectionStatus(afterSubmit, collectionA)
	bSubmit := collectionStatus(afterSubmit, collectionB)
	fmt.Printf("AFTER_SUBMIT overall_finished=%v next_scheduled=%v a_in_progress=%v b_in_progress=%v statuses=%d\n",
		afterSubmit.Status.Finished, afterSubmit.Status.NextScheduledTime != nil,
		aSubmit.InProgress, bSubmit.InProgress, len(afterSubmit.Status.CollectionBackupStatuses))
	if firstResult.RequeueAfter <= 0 || !aSubmit.InProgress || !bSubmit.InProgress {
		panic("the normal first reconcile did not submit both collection backups")
	}

	// A user now deletes A via Solr's public Collections API. The already
	// completed BACKUP async response remains available under its request ID.
	deleteURL := "http://solr.test/solr/admin/collections?action=DELETE&name=" + collectionA + "&wt=json"
	resp, err := httpClient.Get(deleteURL)
	must(err)
	deleteBody, err := io.ReadAll(resp.Body)
	must(err)
	must(resp.Body.Close())
	fmt.Printf("PUBLIC_DELETE status=%d body=%s\n", resp.StatusCode, strings.TrimSpace(string(deleteBody)))

	// Multiple normal requeues prove this is not a transient snapshot. B is
	// polled and completed; A is retained in CR status but never polled again.
	for iteration := 2; iteration <= 6; iteration++ {
		result := reconcile(ctx, reconciler, iteration)
		current := getBackup(ctx, kube)
		a := collectionStatus(current, collectionA)
		b := collectionStatus(current, collectionB)
		fmt.Printf("AFTER_RELIST_%d overall_finished=%v next_scheduled=%v a_in_progress=%v a_finished=%v b_finished=%v\n",
			iteration, current.Status.Finished, current.Status.NextScheduledTime != nil,
			a.InProgress, a.Finished, b.Finished)
		if result.RequeueAfter <= 0 {
			panic("controller stopped its normal polling requeue unexpectedly")
		}
	}

	finalBackup := getBackup(ctx, kube)
	finalA := collectionStatus(finalBackup, collectionA)
	finalB := collectionStatus(finalBackup, collectionB)
	aRequestID := backupName + "-" + collectionA
	bRequestID := backupName + "-" + collectionB

	peer.mu.Lock()
	aTaskState, aTaskStillStored := peer.tasks[aRequestID]
	listCalls := peer.listCalls
	aBackupCalls := peer.backupCalls[collectionA]
	bBackupCalls := peer.backupCalls[collectionB]
	aPollCalls := peer.pollCalls[aRequestID]
	bPollCalls := peer.pollCalls[bRequestID]
	aDeleteStatusCalls := peer.deleteCalls[aRequestID]
	bDeleteStatusCalls := peer.deleteCalls[bRequestID]
	peer.mu.Unlock()

	fmt.Printf("SOLR_CALLS list=%d backup_a=%d backup_b=%d poll_a=%d poll_b=%d delete_status_a=%d delete_status_b=%d\n",
		listCalls, aBackupCalls, bBackupCalls, aPollCalls, bPollCalls, aDeleteStatusCalls, bDeleteStatusCalls)
	fmt.Printf("ASYNC_A retained=%v state=%s\n", aTaskStillStored, aTaskState)
	fmt.Printf("FINAL_CR overall_finished=%v successful_set=%v next_scheduled=%v a_in_progress=%v a_finished=%v b_finished=%v\n",
		finalBackup.Status.Finished, finalBackup.Status.Successful != nil,
		finalBackup.Status.NextScheduledTime != nil, finalA.InProgress, finalA.Finished, finalB.Finished)

	if listCalls != 6 || aBackupCalls != 1 || bBackupCalls != 1 {
		panic("unexpected discovery/submission call sequence")
	}
	if aPollCalls != 0 || !aTaskStillStored || aTaskState != "completed" {
		panic("test did not demonstrate the submitted A task being dropped from polling")
	}
	if bPollCalls != 1 || bDeleteStatusCalls != 1 || aDeleteStatusCalls != 0 {
		panic("control collection did not complete through the normal status lifecycle")
	}
	if !finalA.InProgress || finalA.Finished || !finalB.Finished || finalBackup.Status.Finished || finalBackup.Status.NextScheduledTime != nil {
		panic("persisted SolrBackup status did not exhibit the stranded run/recurrence")
	}

	fmt.Println("BUG_TRIGGERED: completed async backup A was never polled after DELETE removed A from LIST; the real Reconcile consumer kept the run unfinished and recurrence unscheduled across five later loops")
}
