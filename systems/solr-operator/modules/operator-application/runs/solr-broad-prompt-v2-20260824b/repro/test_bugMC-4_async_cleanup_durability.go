// Reproduction for MC-4 against the real SolrBackup Reconcile entry point.
//
// Escalation:
//
//	Level 0: the same public control flow, uninterrupted, persists success.
//	Level 1: cancellation is timed immediately after Solr accepts DELETESTATUS,
//	representing controller loss. No operator source or precondition is patched.
//
// The Solr transport below implements only valid Collections API responses. The
// controller and its Kubernetes status consumer are the production code under
// test; the fake client is a durable API-store substitute and deliberately
// honors context cancellation the way a real Kubernetes client does.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	solrv1beta1 "github.com/apache/solr-operator/api/v1beta1"
	"github.com/apache/solr-operator/controllers"
	"github.com/apache/solr-operator/controllers/util/solr_api"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

const (
	namespace  = "mc4"
	cloudName  = "cloud"
	backupName = "backup"
	collection = "books"
	asyncID    = backupName + "-" + collection
)

type solrState struct {
	mu             sync.Mutex
	submitted      bool
	completed      bool
	recordPresent  bool
	requestStatus  int
	deleteStatus   int
	backupRequests int
	cancelOnDelete context.CancelFunc
}

type solrRoundTripper struct{ state *solrState }

func jsonResponse(value any) *http.Response {
	body, err := json.Marshal(value)
	must(err)
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     make(http.Header),
		Body:       io.NopCloser(strings.NewReader(string(body))),
	}
}

func (rt solrRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	q := req.URL.Query()
	if req.URL.Path != "/solr/admin/collections" || q.Get("wt") != "json" {
		return nil, fmt.Errorf("unexpected Solr request: %s", req.URL.String())
	}

	rt.state.mu.Lock()
	defer rt.state.mu.Unlock()

	switch q.Get("action") {
	case "BACKUP":
		require(q.Get("collection") == collection, "BACKUP collection mismatch: %q", q.Get("collection"))
		require(q.Get("async") == asyncID, "BACKUP async id mismatch: %q", q.Get("async"))
		rt.state.backupRequests++
		rt.state.submitted = true
		rt.state.recordPresent = true
		return jsonResponse(map[string]any{
			"responseHeader": map[string]any{"status": 0, "QTime": 1},
			"requestId":      asyncID,
		}), nil

	case "REQUESTSTATUS":
		require(q.Get("requestid") == asyncID, "REQUESTSTATUS id mismatch: %q", q.Get("requestid"))
		rt.state.requestStatus++
		state := "notfound"
		if rt.state.recordPresent {
			if rt.state.completed {
				state = "completed"
			} else {
				state = "running"
			}
		}
		return jsonResponse(map[string]any{
			"responseHeader": map[string]any{"status": 0, "QTime": 1},
			"status":         map[string]any{"state": state},
		}), nil

	case "DELETESTATUS":
		require(q.Get("requestid") == asyncID, "DELETESTATUS id mismatch: %q", q.Get("requestid"))
		require(rt.state.recordPresent && rt.state.completed,
			"DELETESTATUS was not issued for a completed tracked request")
		rt.state.deleteStatus++
		rt.state.recordPresent = false
		cancel := rt.state.cancelOnDelete
		rt.state.cancelOnDelete = nil
		// This is the Level-1 timing assistance: the controller loses its
		// reconcile context only after Solr has durably deleted the record.
		if cancel != nil {
			cancel()
		}
		return jsonResponse(map[string]any{
			"responseHeader": map[string]any{"status": 0, "QTime": 1},
			"status":         "successfully removed stored response for " + asyncID,
		}), nil
	default:
		return nil, fmt.Errorf("unexpected Solr action %q", q.Get("action"))
	}
}

type harness struct {
	client     client.Client
	reconciler *controllers.SolrBackupReconciler
	solr       *solrState
	req        ctrl.Request
}

func newHarness() *harness {
	scheme := runtime.NewScheme()
	must(solrv1beta1.AddToScheme(scheme))

	cloud := &solrv1beta1.SolrCloud{
		ObjectMeta: metav1.ObjectMeta{Name: cloudName, Namespace: namespace},
		Spec: solrv1beta1.SolrCloudSpec{
			BackupRepositories: []solrv1beta1.SolrBackupRepository{{
				Name: "repo",
				S3:   &solrv1beta1.S3Repository{Region: "test", Bucket: "bucket"},
			}},
		},
		Status: solrv1beta1.SolrCloudStatus{
			Version:                     "9.10.0",
			BackupRepositoriesAvailable: map[string]bool{"repo": true},
		},
	}
	backup := &solrv1beta1.SolrBackup{
		ObjectMeta: metav1.ObjectMeta{Name: backupName, Namespace: namespace},
		Spec: solrv1beta1.SolrBackupSpec{
			SolrCloud:      cloudName,
			RepositoryName: "repo",
			Collections:    []string{collection},
		},
	}

	// The fake store keeps status separate, like the real CRD status
	// subresource. The interceptor adds only real-client context behavior.
	cl := fake.NewClientBuilder().
		WithScheme(scheme).
		WithStatusSubresource(&solrv1beta1.SolrBackup{}).
		WithObjects(cloud, backup).
		WithInterceptorFuncs(interceptor.Funcs{
			SubResourcePatch: func(ctx context.Context, c client.Client, name string, obj client.Object, patch client.Patch, opts ...client.SubResourcePatchOption) error {
				if err := ctx.Err(); err != nil {
					return err
				}
				return c.SubResource(name).Patch(ctx, obj, patch, opts...)
			},
		}).
		Build()

	solr := &solrState{}
	solr_api.SetNoVerifyTLSHttpClient(&http.Client{Transport: solrRoundTripper{state: solr}})
	return &harness{
		client: cl,
		reconciler: &controllers.SolrBackupReconciler{
			Client:   cl,
			Scheme:   scheme,
			Recorder: record.NewFakeRecorder(20),
		},
		solr: solr,
		req: ctrl.Request{NamespacedName: client.ObjectKey{
			Namespace: namespace,
			Name:      backupName,
		}},
	}
}

func (h *harness) reconcile(ctx context.Context) (ctrl.Result, error) {
	return h.reconciler.Reconcile(ctx, h.req)
}

func (h *harness) storedBackup() *solrv1beta1.SolrBackup {
	backup := &solrv1beta1.SolrBackup{}
	must(h.client.Get(context.Background(), h.req.NamespacedName, backup))
	return backup
}

func (h *harness) completeInSolr() {
	h.solr.mu.Lock()
	defer h.solr.mu.Unlock()
	require(h.solr.submitted && h.solr.recordPresent, "cannot complete an unsubmitted backup")
	h.solr.completed = true
}

func statusLine(prefix string, backup *solrv1beta1.SolrBackup) string {
	cs := backup.Status.CollectionBackupStatuses[0]
	successful := "nil"
	if cs.Successful != nil {
		successful = fmt.Sprintf("%v", *cs.Successful)
	}
	return fmt.Sprintf("%s inProgress=%v finished=%v successful=%s asyncStatus=%q",
		prefix, cs.InProgress, cs.Finished, successful, cs.AsyncBackupStatus)
}

func level0Control() {
	h := newHarness()
	result, err := h.reconcile(context.Background())
	must(err)
	require(result.RequeueAfter == 5*time.Second, "initial reconcile did not request polling: %v", result)
	require(h.storedBackup().Status.CollectionBackupStatuses[0].InProgress,
		"BACKUP acceptance was not persisted")

	h.completeInSolr()
	result, err = h.reconcile(context.Background())
	must(err)
	stored := h.storedBackup()
	require(stored.Status.Finished, "uninterrupted reconcile did not persist terminal status")
	require(stored.Status.Successful != nil && *stored.Status.Successful,
		"uninterrupted reconcile did not persist success")
	require(h.solr.deleteStatus == 1, "uninterrupted reconcile did not clean up once")
	fmt.Println("LEVEL0 CONTROL: uninterrupted REQUESTSTATUS(completed) -> DELETESTATUS -> status patch")
	fmt.Println(statusLine("LEVEL0 STORED:", stored))
}

func level1ControllerLoss() {
	h := newHarness()
	result, err := h.reconcile(context.Background())
	must(err)
	require(result.RequeueAfter == 5*time.Second, "initial reconcile did not request polling: %v", result)
	h.completeInSolr()

	terminalCtx, cancel := context.WithCancel(context.Background())
	h.solr.mu.Lock()
	h.solr.cancelOnDelete = cancel
	h.solr.mu.Unlock()
	result, err = h.reconcile(terminalCtx)
	require(errors.Is(err, context.Canceled), "terminal reconcile error=%v, want context.Canceled", err)
	require(h.solr.deleteStatus == 1 && !h.solr.recordPresent,
		"Solr terminal record was not deleted before cancellation")
	stored := h.storedBackup()
	require(!stored.Status.Finished && stored.Status.CollectionBackupStatuses[0].InProgress,
		"terminal status unexpectedly became durable after cancellation")
	fmt.Println("LEVEL1 TRIGGER: controller context canceled immediately after successful DELETESTATUS")
	fmt.Printf("LEVEL1 TERMINAL RECONCILE: error=%v deleteStatusCalls=%d recordPresent=%v\n",
		err, h.solr.deleteStatus, h.solr.recordPresent)
	fmt.Println(statusLine("LEVEL1 STORED AFTER LOSS:", stored))

	for i := 1; i <= 3; i++ {
		result, err = h.reconcile(context.Background())
		must(err)
		stored = h.storedBackup()
		cs := stored.Status.CollectionBackupStatuses[0]
		require(result.RequeueAfter == 5*time.Second,
			"post-loss reconcile %d did not keep polling: %v", i, result)
		require(cs.InProgress && !cs.Finished && cs.Successful == nil,
			"post-loss reconcile %d unexpectedly reached a terminal state: %+v", i, cs)
		require(cs.AsyncBackupStatus == "notfound",
			"post-loss reconcile %d status=%q, want notfound", i, cs.AsyncBackupStatus)
		fmt.Printf("POST-LOSS RECONCILE %d: requeueAfter=%s %s\n",
			i, result.RequeueAfter, statusLine("stored", stored))
	}
	require(h.solr.backupRequests == 1,
		"controller unexpectedly resubmitted the backup %d times", h.solr.backupRequests)
	require(h.solr.deleteStatus == 1,
		"controller unexpectedly repeated cleanup %d times", h.solr.deleteStatus)
	fmt.Printf("REAL CONSUMER OUTCOME: SolrBackup Reconcile keeps polling notfound; backupCalls=%d deleteStatusCalls=%d requestStatusCalls=%d\n",
		h.solr.backupRequests, h.solr.deleteStatus, h.solr.requestStatus)
	fmt.Println("BUG REPRODUCED: terminal evidence is gone, durable status remains inProgress, and repeated reconciliation does not recover or resubmit")
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "FAIL:", err)
		os.Exit(1)
	}
}

func require(ok bool, format string, args ...any) {
	if !ok {
		fmt.Fprintf(os.Stderr, "FAIL: "+format+"\n", args...)
		os.Exit(1)
	}
}

// Keep url imported as a compile-time check that the transport sees parsed
// Collections API queries rather than hand-decoded strings.
var _ = url.Values{}

func main() {
	level0Control()
	level1ControllerLoss()
}
