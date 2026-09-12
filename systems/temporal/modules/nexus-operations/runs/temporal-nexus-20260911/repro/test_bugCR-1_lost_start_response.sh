#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/confirmation/CR-1/worktree"
TEST_FILE="$WORKTREE/service/history/hsm/nexusoperations/cr1_lost_start_response_test.go"
TEST_NAME="TestCR1LostAcceptedStartResponseAcceptsStaleDuplicateCompletion"

cleanup() {
  rm -f "$TEST_FILE"
}
trap cleanup EXIT

cat >"$TEST_FILE" <<'GOEOF'
package nexusoperations_test

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sync"
	"testing"
	"time"

	"github.com/nexus-rpc/sdk-go/nexus"
	"github.com/stretchr/testify/require"
	historypb "go.temporal.io/api/history/v1"
	"go.temporal.io/api/serviceerror"
	enumsspb "go.temporal.io/server/api/enums/v1"
	persistencespb "go.temporal.io/server/api/persistence/v1"
	"go.temporal.io/server/common/backoff"
	"go.temporal.io/server/common/definition"
	"go.temporal.io/server/common/dynamicconfig"
	"go.temporal.io/server/common/log"
	"go.temporal.io/server/common/metrics"
	"go.temporal.io/server/common/namespace"
	commonnexus "go.temporal.io/server/common/nexus"
	"go.temporal.io/server/common/nexus/nexusrpc"
	"go.temporal.io/server/common/nexus/nexustest"
	"go.temporal.io/server/service/history/hsm"
	"go.temporal.io/server/service/history/hsm/hsmtest"
	"go.temporal.io/server/service/history/hsm/nexusoperations"
	queueserrors "go.temporal.io/server/service/history/queues/errors"
	"go.uber.org/mock/gomock"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/durationpb"
)

func TestCR1LostAcceptedStartResponseAcceptsStaleDuplicateCompletion(t *testing.T) {
	ctrl := gomock.NewController(t)
	listenAddr := nexustest.AllocListenAddress()

	var mu sync.Mutex
	var requestIDs []string
	var operationTokens []string
	handler := nexustest.Handler{}
	handler.OnStartOperation = func(
		ctx context.Context,
		service, operation string,
		input *nexus.LazyValue,
		options nexus.StartOperationOptions,
	) (nexus.HandlerStartOperationResult[any], error) {
		mu.Lock()
		defer mu.Unlock()

		token := fmt.Sprintf("token-%d", len(operationTokens)+1)
		requestIDs = append(requestIDs, options.RequestID)
		operationTokens = append(operationTokens, token)
		t.Logf("endpoint accepted StartOperation request_id=%s operation_token=%s", options.RequestID, token)
		return &nexus.HandlerStartOperationResultAsync{OperationToken: token}, nil
	}
	nexustest.NewNexusServer(t, listenAddr, handler)

	reg := newRegistry(t)
	scheduled := mustNewScheduledEvent(time.Now(), &historypb.NexusOperationScheduledEventAttributes{
		ScheduleToCloseTimeout: durationpb.New(time.Hour),
		ScheduleToStartTimeout: durationpb.New(time.Hour),
		StartToCloseTimeout:    durationpb.New(time.Hour),
	})
	scheduledRequestID := scheduled.GetNexusOperationScheduledEventAttributes().GetRequestId()
	backend := &hsmtest.NodeBackend{Events: []*historypb.HistoryEvent{scheduled}}
	node := newOperationNode(t, backend, scheduled)
	env := fakeEnv{node}

	namespaceRegistry := namespace.NewMockRegistry(ctrl)
	namespaceRegistry.EXPECT().GetNamespaceByID(namespace.ID("ns-id")).Return(
		namespace.NewNamespaceForTest(&persistencespb.NamespaceInfo{Name: "ns-name"}, nil, false, nil, 0), nil,
	).AnyTimes()

	endpointReg := nexustest.FakeEndpointRegistry{
		OnGetByID: func(ctx context.Context, endpointID string) (*persistencespb.NexusEndpointEntry, error) {
			require.Equal(t, "endpoint-id", endpointID)
			return endpointEntry, nil
		},
		OnGetByName: func(ctx context.Context, namespaceID namespace.ID, endpointName string) (*persistencespb.NexusEndpointEntry, error) {
			require.Equal(t, "endpoint", endpointName)
			return endpointEntry, nil
		},
	}

	var httpAttempts int
	httpCaller := func(req *http.Request) (*http.Response, error) {
		mu.Lock()
		httpAttempts++
		attempt := httpAttempts
		mu.Unlock()

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return resp, err
		}
		if attempt == 1 {
			if resp != nil && resp.Body != nil {
				_, _ = io.Copy(io.Discard, resp.Body)
				_ = resp.Body.Close()
			}
			return nil, &url.Error{Op: req.Method, URL: req.URL.String(), Err: context.DeadlineExceeded}
		}
		return resp, nil
	}

	require.NoError(t, nexusoperations.RegisterExecutor(reg, nexusoperations.TaskExecutorOptions{
		Config: &nexusoperations.Config{
			RequestTimeout:          dynamicconfig.GetDurationPropertyFnFilteredByDestination(time.Hour),
			MaxOperationTokenLength: dynamicconfig.GetIntPropertyFnFilteredByNamespace(1000),
			MinRequestTimeout:       dynamicconfig.GetDurationPropertyFnFilteredByNamespace(time.Millisecond),
			PayloadSizeLimit:        dynamicconfig.GetIntPropertyFnFilteredByNamespace(2 * 1024 * 1024),
			CallbackURLTemplate:     dynamicconfig.GetStringPropertyFn("http://localhost/callback"),
			UseNewFailureWireFormat: dynamicconfig.GetBoolPropertyFnFilteredByNamespace(true),
			RetryPolicy: func() backoff.RetryPolicy {
				return backoff.NewExponentialRetryPolicy(time.Millisecond)
			},
		},
		CallbackTokenGenerator: commonnexus.NewCallbackTokenGenerator(),
		NamespaceRegistry:      namespaceRegistry,
		MetricsHandler:         metrics.NoopMetricsHandler,
		Logger:                 log.NewNoopLogger(),
		EndpointRegistry:       endpointReg,
		ClientProvider: func(ctx context.Context, namespaceID string, entry *persistencespb.NexusEndpointEntry, service string) (*nexusrpc.HTTPClient, error) {
			return nexusrpc.NewHTTPClient(nexusrpc.HTTPClientOptions{
				BaseURL:    "http://" + listenAddr,
				Service:    service,
				Serializer: commonnexus.PayloadSerializer,
				HTTPCaller: httpCaller,
			})
		},
	}))

	ref := hsm.Ref{
		WorkflowKey:     definition.NewWorkflowKey("ns-id", "wf-id", "run-id"),
		StateMachineRef: &persistencespb.StateMachineRef{},
	}
	err := reg.ExecuteImmediateTask(context.Background(), env, ref, nexusoperations.InvocationTask{EndpointName: "endpoint-id"})
	var down *queueserrors.DestinationDownError
	require.ErrorAs(t, err, &down)
	op, err := hsm.MachineData[nexusoperations.Operation](node)
	require.NoError(t, err)
	require.Equal(t, enumsspb.NEXUS_OPERATION_STATE_BACKING_OFF, op.State())
	require.Equal(t, int32(1), op.Attempt)
	require.Len(t, backend.Events, 1, "lost accepted start response should not persist a started event")

	mu.Lock()
	require.Equal(t, []string{scheduledRequestID}, append([]string(nil), requestIDs...))
	require.Equal(t, []string{"token-1"}, append([]string(nil), operationTokens...))
	mu.Unlock()
	t.Logf("Temporal treated the accepted first response as lost and moved to BACKING_OFF request_id=%s", scheduledRequestID)

	require.NoError(t, reg.ExecuteTimerTask(env, node, nexusoperations.BackoffTask{}))
	op, err = hsm.MachineData[nexusoperations.Operation](node)
	require.NoError(t, err)
	require.Equal(t, enumsspb.NEXUS_OPERATION_STATE_SCHEDULED, op.State())

	require.NoError(t, reg.ExecuteImmediateTask(context.Background(), env, ref, nexusoperations.InvocationTask{
		EndpointName: "endpoint-id",
		Attempt:      1,
	}))
	op, err = hsm.MachineData[nexusoperations.Operation](node)
	require.NoError(t, err)
	require.Equal(t, enumsspb.NEXUS_OPERATION_STATE_STARTED, op.State())
	require.Equal(t, int32(2), op.Attempt)
	require.Equal(t, "token-2", op.OperationToken)

	mu.Lock()
	require.Equal(t, []string{scheduledRequestID, scheduledRequestID}, append([]string(nil), requestIDs...))
	require.Equal(t, []string{"token-1", "token-2"}, append([]string(nil), operationTokens...))
	mu.Unlock()

	started := backend.Events[len(backend.Events)-1].GetNexusOperationStartedEventAttributes()
	require.NotNil(t, started)
	require.Equal(t, scheduledRequestID, started.GetRequestId())
	require.Equal(t, "token-2", started.GetOperationToken())
	t.Logf("retry persisted local STARTED with request_id=%s operation_token=%s", started.GetRequestId(), started.GetOperationToken())

	completionHandler := nexusoperations.NewCompletionHandler(metrics.NoopMetricsHandler, &nexusoperations.Config{})
	wrongRequestErr := completionHandler.Handle(
		context.Background(),
		env,
		ref,
		"wrong-"+scheduledRequestID,
		"token-1",
		nil,
		nil,
		mustToPayload(t, "wrong-request"),
		nil,
	)
	var notFound *serviceerror.NotFound
	require.ErrorAs(t, wrongRequestErr, &notFound)
	op, err = hsm.MachineData[nexusoperations.Operation](node)
	require.NoError(t, err)
	require.Equal(t, enumsspb.NEXUS_OPERATION_STATE_STARTED, op.State())
	require.Len(t, backend.Events, 2, "mismatched request-id control must not record completion")
	t.Logf("control rejected mismatched completion request_id=%s operation_token=token-1", "wrong-"+scheduledRequestID)

	staleResult := mustToPayload(t, "completed-by-token-1")
	require.NoError(t, completionHandler.Handle(
		context.Background(),
		env,
		ref,
		scheduledRequestID,
		"token-1",
		nil,
		nil,
		staleResult,
		nil,
	))
	op, err = hsm.MachineData[nexusoperations.Operation](node)
	require.NoError(t, err)
	require.Equal(t, enumsspb.NEXUS_OPERATION_STATE_SUCCEEDED, op.State())
	completed := backend.Events[len(backend.Events)-1].GetNexusOperationCompletedEventAttributes()
	require.NotNil(t, completed)
	require.Equal(t, scheduledRequestID, completed.GetRequestId())
	require.True(t, proto.Equal(staleResult, completed.GetResult()))
	t.Logf(
		"completion accepted request_id=%s callback_operation_token=token-1 while persisted_operation_token=token-2 result=completed-by-token-1",
		completed.GetRequestId(),
	)
}
GOEOF

cd "$WORKTREE"
echo "CR-1 repro source revision: $(git rev-parse HEAD)"
echo "CR-1 repro command: timeout 10m go test -count=1 -run $TEST_NAME ./service/history/hsm/nexusoperations -v"
timeout 10m go test -count=1 -run "$TEST_NAME" ./service/history/hsm/nexusoperations -v
