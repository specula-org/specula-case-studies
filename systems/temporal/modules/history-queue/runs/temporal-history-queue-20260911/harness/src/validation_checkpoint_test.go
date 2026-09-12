package shard

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"go.temporal.io/server/common/locks"
	"go.temporal.io/server/common/persistence"
	"go.uber.org/mock/gomock"
)

type validationObservedSemaphore struct {
	locks.PrioritySemaphore
	entered chan struct{}
}

func (s *validationObservedSemaphore) Acquire(ctx context.Context, priority locks.Priority, n int) error {
	close(s.entered)
	return s.PrioritySemaphore.Acquire(ctx, priority, n)
}

func TestValidationCheckpointSemaphoreLifecycle(t *testing.T) {
	for _, stop := range []bool{false, true} {
		name := "finite_contention_control"
		if stop {
			name = "stop_cancels_wait"
		}
		t.Run(name, func(t *testing.T) {
			s := new(contextSuite)
			s.SetT(t)
			s.SetupTest()
			sc := s.mockShard
			now := time.Now().UTC()
			s.timeSource.Update(now)
			sc.lastUpdated = now.Add(-time.Hour)
			sem := locks.NewPrioritySemaphore(1)
			require.NoError(t, sem.Acquire(context.Background(), locks.PriorityHigh, 1))
			observed := &validationObservedSemaphore{PrioritySemaphore: sem, entered: make(chan struct{})}
			sc.ioSemaphore = observed
			writes := 0
			s.mockShardManager.EXPECT().UpdateShard(gomock.Any(), gomock.Any()).DoAndReturn(func(context.Context, *persistence.UpdateShardRequest) error { writes++; return nil }).AnyTimes()
			result := make(chan error, 1)
			go func() { result <- sc.updateShardInfo(7, func() {}) }()
			select {
			case <-observed.entered:
			case <-time.After(5 * time.Second):
				t.Fatal("did not reach real semaphore")
			}
			require.Equal(t, now, sc.lastUpdated)
			require.Zero(t, sc.tasksCompletedSinceLastUpdate)
			_, hasDeadline := sc.lifecycleCtx.Deadline()
			require.False(t, hasDeadline)
			if stop {
				require.NoError(t, sc.transition(contextRequestStop{}))
			} else {
				sem.Release(1)
			}
			select {
			case err := <-result:
				if stop {
					require.ErrorIs(t, err, context.Canceled)
				} else {
					require.NoError(t, err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("semaphore wait did not finish")
			}
			if stop {
				sem.Release(1)
				require.Zero(t, writes)
				require.Equal(t, contextStateStopping, sc.state)
			} else {
				require.Equal(t, 1, writes)
			}
			t.Logf("CR-3 stop=%t real_priority_semaphore=true lifecycle_deadline=false writes=%d bookkeeping_advanced=true; finite contention succeeds, cancellation belongs to shutdown", stop, writes)
		})
	}
}
