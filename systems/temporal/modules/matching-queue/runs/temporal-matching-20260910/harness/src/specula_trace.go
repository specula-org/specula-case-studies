package matching

import (
	"context"
	"sync/atomic"

	sqlstore "go.temporal.io/server/common/persistence/sql"
)

type speculaTraceCallbacks struct {
	probe func(string, ...any)
	owner func(*taskQueueDB) int
}

var speculaCallbacks atomic.Pointer[speculaTraceCallbacks]

func speculaProbe(point string, args ...any) {
	if c := speculaCallbacks.Load(); c != nil {
		c.probe(point, args...)
	}
}
func speculaDBContext(ctx context.Context, db *taskQueueDB) context.Context {
	if c := speculaCallbacks.Load(); c != nil {
		return context.WithValue(ctx, sqlstore.SpeculaOwnerKey{}, c.owner(db))
	}
	return ctx
}
