package sql

import (
	"context"
	"sync/atomic"
)

type SpeculaOwnerKey struct{}
type SpeculaTraceCallback struct {
	Probe func(context.Context, string, ...any)
}

var SpeculaCallback atomic.Pointer[SpeculaTraceCallback]

func SpeculaProbe(ctx context.Context, point string, args ...any) {
	if c := SpeculaCallback.Load(); c != nil {
		c.Probe(ctx, point, args...)
	}
}
