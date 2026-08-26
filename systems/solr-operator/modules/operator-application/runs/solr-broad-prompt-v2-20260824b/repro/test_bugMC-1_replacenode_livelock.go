// Reproduction for MC-1:
//
//	REPLACENODE issued during scale-down when <2 Solr nodes are live ->
//	Solr returns HTTP 400 -> operator's v1 client collapses it into an opaque
//	ServiceUnavailable (503-semantics) -> EvictReplicasForPodIfNecessary returns
//	err!=nil, canDeletePod=false, requestInProgress=false -> ScaleDownLock retained
//	-> level-triggered reconcile re-submits the identical impossible REPLACENODE
//	forever (livelock).
//
// Escalation level: Level 2 (state injection). The injected pre-condition is the
// reachable "<=1 live Solr node" state (CE MC_hunt_s4.out: MCSolrNodeDown(n0),
// MCSolrNodeDown(n1) => liveNodes={n2}; transient ZK-session loss / node churn is
// an admissible fault). Solr's response is NOT fabricated: the RoundTripper returns
// exactly what ReplaceNodeCmd.java:59-67 produces for that state
// (HTTP 400 "No nodes other than the source node ... are live"). We drive the REAL
// operator entry point EvictReplicasForPodIfNecessary and its real HTTP client hook.
package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/record"
	"k8s.io/utils/pointer"

	solr "github.com/apache/solr-operator/api/v1beta1"
	"github.com/apache/solr-operator/controllers/util"
	"github.com/apache/solr-operator/controllers/util/solr_api"
)

// fakeSolr faithfully emulates Solr in the reachable "<=1 live node" state.
type fakeSolr struct {
	replaceNodeCalls   int
	requestStatusCalls int
	sourceNode         string
}

func (f *fakeSolr) RoundTrip(req *http.Request) (*http.Response, error) {
	action := req.URL.Query().Get("action")
	mk := func(status int, body string) *http.Response {
		return &http.Response{
			StatusCode: status,
			Body:       io.NopCloser(strings.NewReader(body)),
			Header:     make(http.Header),
			Request:    req,
		}
	}
	switch action {
	case "REQUESTSTATUS":
		// Async id was never accepted (REPLACENODE keeps failing synchronously),
		// so Solr reports the request id as not found -> operator (re)submits.
		f.requestStatusCalls++
		return mk(200, `{"responseHeader":{"status":0},"status":{"state":"notfound","msg":"Did not find [move-replicas] in any tasks queue"}}`), nil
	case "REPLACENODE":
		// Verbatim shape of ReplaceNodeCmd.java:62-67 BAD_REQUEST (HTTP 400).
		f.replaceNodeCalls++
		f.sourceNode = req.URL.Query().Get("sourceNode")
		body := fmt.Sprintf(`{"responseHeader":{"status":400,"QTime":5},"error":{"metadata":["error-class","org.apache.solr.common.SolrException","root-error-class","org.apache.solr.common.SolrException"],"msg":"No nodes other than the source node: %s are live, therefore replicas cannot be moved","code":400}}`, f.sourceNode)
		return mk(400, body), nil
	default:
		return mk(200, `{"responseHeader":{"status":0}}`), nil
	}
}

func main() {
	fs := &fakeSolr{}
	// Inject our faithful Solr into the operator's REAL http client hook.
	solr_api.SetNoVerifyTLSHttpClient(&http.Client{Transport: fs})

	replicas := int32(2) // >=2 => EvictReplicasForPodIfNecessary takes the REPLACENODE branch
	sc := &solr.SolrCloud{
		ObjectMeta: metav1.ObjectMeta{Name: "test", Namespace: "default"},
		Spec:       solr.SolrCloudSpec{Replicas: pointer.Int32(replicas)},
	}
	sc.WithDefaults(logr.Discard())

	pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Name: "test-solrcloud-2"}}
	recorder := record.NewFakeRecorder(1000)
	ctx := context.Background()

	fmt.Println("=== MC-1 reproduction: REPLACENODE precondition livelock ===")
	fmt.Printf("Simulating a healthy source pod (%s) being scaled down while Solr has <=1 live node.\n\n", pod.Name)

	const reconciles = 5
	livelock := true
	var lastErr error
	for i := 1; i <= reconciles; i++ {
		before := fs.replaceNodeCalls
		err, canDeletePod, requestInProgress := util.EvictReplicasForPodIfNecessary(
			ctx, sc, pod, true /*podHasReplicas*/, "scaleDown", recorder, logr.Discard())
		lastErr = err
		submitted := fs.replaceNodeCalls - before
		fmt.Printf("reconcile #%d: REPLACENODE submitted=%d  canDeletePod=%v  requestInProgress=%v  isServiceUnavailable=%v\n",
			i, submitted, canDeletePod, requestInProgress, errors.IsServiceUnavailable(err))
		fmt.Printf("            err = %v\n", err)
		// Livelock signature: each reconcile re-issues the impossible REPLACENODE,
		// gets an opaque error, and cannot delete the pod / make progress.
		if !(submitted == 1 && err != nil && !canDeletePod && !requestInProgress) {
			livelock = false
		}
	}

	fmt.Println()
	// The operator cannot tell this permanent semantic 400 from a transient 503:
	// the error is ServiceUnavailable and the 400 body/code was discarded.
	semanticInfoLost := errors.IsServiceUnavailable(lastErr) &&
		!strings.Contains(fmt.Sprintf("%T", lastErr), "APIError")

	fmt.Printf("Total REPLACENODE submissions across %d reconciles: %d\n", reconciles, fs.replaceNodeCalls)
	fmt.Printf("Opaque-error collapse (semantic 400 -> ServiceUnavailable, code lost): %v\n", semanticInfoLost)
	fmt.Printf("Livelock (identical impossible call re-issued every reconcile, no progress): %v\n", livelock)

	if livelock && semanticInfoLost && fs.replaceNodeCalls == reconciles {
		fmt.Println("\nRESULT: BUG REPRODUCED — precondition-livelock with opaque error collapse.")
		os.Exit(0)
	}
	fmt.Println("\nRESULT: NOT reproduced.")
	os.Exit(1)
}
