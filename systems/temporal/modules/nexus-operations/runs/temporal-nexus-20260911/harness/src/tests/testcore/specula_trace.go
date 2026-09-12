package testcore

import (
 "os"
 chasmnexus "go.temporal.io/server/chasm/lib/nexusoperation"
 "go.temporal.io/server/common/dynamicconfig"
 "go.temporal.io/server/common/log"
 "go.temporal.io/server/common/speculatrace"
 "go.temporal.io/server/service/history/hsm/nexusoperations"
)

func (e *TestEnv) SpeculaConfig() map[string]any {
 c := dynamicconfig.NewCollection(e.cluster.host.dcClient, log.NewNoopLogger())
 ns := e.Namespace().String()
 p := e.cluster.host.serverConfig.Persistence
 sql := p.DataStores[p.DefaultStore].SQL
 return map[string]any{
  "recordingKind":"implementation-raw", "binarySha256":os.Getenv("SPECULA_BINARY_SHA256"), "sourceRevision":speculatrace.Revision,
  "route":"legacy-hsm", "backend":sql.PluginName, "connect_attributes": sql.ConnectAttributes,
  "transitionHistory":dynamicconfig.EnableTransitionHistory.Get(c)(ns),
  "cancelAckEvents":nexusoperations.RecordCancelRequestCompletionEvents.Get(c)(),
  "outboundBatchSize":dynamicconfig.OutboundTaskBatchSize.Get(c)(),
  "chasmWorkflowOperations":chasmnexus.EnableChasmWorkflowOperations.Get(c)(ns),
  "chasmRollout":chasmnexus.ChasmWorkflowOperationsRolloutPercent.Get(c)(ns),
  "Capacity":nexusoperations.MaxConcurrentOperations.Get(c)(ns),
  "RequestTimeoutNS":int64(nexusoperations.RequestTimeout.Get(c)(ns,"")),
  "MinRequestTimeoutNS":int64(nexusoperations.MinRequestTimeout.Get(c)(ns)),
  "RetryInitialNS":int64(nexusoperations.RetryPolicyInitialInterval.Get(c)()),
  "RetryMaximumNS":int64(nexusoperations.RetryPolicyMaximumInterval.Get(c)()),
  "callback_template":nexusoperations.CallbackURLTemplate.Get(c)(),
  "num_shards":p.NumHistoryShards,
 }
}
