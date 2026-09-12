package queues

import (
	"testing"

	"github.com/stretchr/testify/require"
	"go.temporal.io/server/common/definition"
	"go.temporal.io/server/common/metrics"
	"go.temporal.io/server/common/predicates"
	"go.temporal.io/server/service/history/tasks"
	"go.temporal.io/server/service/history/tests"
)

func TestValidationDuplicateTrackerAccounting(t *testing.T) {
	for _, duplicate := range []bool{false, true} {
		name := "disjoint_control"
		if duplicate {
			name = "duplicate_overlap"
		}
		t.Run(name, func(t *testing.T) {
			s := new(sliceSuite)
			s.SetT(t)
			s.SetupTest()
			defer s.TearDownTest()
			key := int64(2)
			if duplicate {
				key = 1
			}
			first := &tasks.WorkflowTask{WorkflowKey: definition.NewWorkflowKey(tests.LocalNamespaceEntry.ID().String(), "validation", "run"), TaskID: 1}
			second := &tasks.WorkflowTask{WorkflowKey: first.WorkflowKey, TaskID: key}
			a, b := newExecutableTracker(GrouperNamespaceID{}), newExecutableTracker(GrouperNamespaceID{})
			a.add(s.executableFactory.NewExecutable(first, 0))
			b.add(s.executableFactory.NewExecutable(second, 1))
			merged := a.merge(b)
			before := len(merged.pendingExecutables)
			require.Equal(t, 2, merged.pendingPerKey[first.NamespaceID])
			for _, e := range merged.pendingExecutables {
				e.Ack()
			}
			_, completed := merged.shrink()
			require.Equal(t, before, completed)
			require.Empty(t, merged.pendingExecutables)
			if duplicate {
				require.Equal(t, 1, before)
				require.Equal(t, 1, merged.pendingPerKey[first.NamespaceID])
			} else {
				require.Equal(t, 2, before)
				require.Empty(t, merged.pendingPerKey)
			}
			z := NewSlice(nil, s.executableFactory, s.monitor, NewScope(NewRange(tasks.NewImmediateKey(1), tasks.NewImmediateKey(3)), predicates.Universal[tasks.Task]()), GrouperNamespaceID{}, noPredicateSizeLimit, defaultMaxPendingKeys, metrics.NoopMetricsHandler)
			z.executableTracker = merged
			z.iterators = nil
			z.ShrinkScope()
			scope := z.Scope()
			require.True(t, scope.IsEmpty())
			t.Logf("CR-2 duplicate=%t retained_keys_before_ack=%d keys_after_ack=%d group_count_after_ack=%d empty_scope_removed=true; controlled overlapping wrappers, no user-visible loss established", duplicate, before, len(merged.pendingExecutables), merged.pendingPerKey[first.NamespaceID])
		})
	}
}
