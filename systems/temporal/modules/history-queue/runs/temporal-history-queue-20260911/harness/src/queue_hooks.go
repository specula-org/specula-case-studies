package queues

import (
	"slices"

	"go.temporal.io/server/common/hqtrace"
)

func hqReaderIDs(m map[int64]Reader) []int64 {
	ids := make([]int64, 0, len(m))
	for id := range m {
		ids = append(ids, id)
	}
	if hqtrace.Enabled {
		slices.Sort(ids)
	}
	return ids
}
func hqScopes(scopes []Scope) []any {
	if !hqtrace.Enabled {
		return nil
	}
	out := []any{}
	for _, s := range scopes {
		out = append(out, hqtrace.M{"lo": s.Range.InclusiveMin.TaskID, "hi": s.Range.ExclusiveMax.TaskID, "predicate": ToPersistencePredicate(s.Predicate)})
	}
	return out
}
func hqSlices(queueSlices []Slice) []any {
	if !hqtrace.Enabled {
		return nil
	}
	out := []any{}
	for _, s := range queueSlices {
		out = append(out, hqSlice(s))
	}
	return out
}

//nolint:revive // The enabled harness only installs concrete SliceImpl objects and namespace group keys.
func hqSlice(z Slice) any {
	s := z.(*SliceImpl)
	its := []any{}
	tr := []string{}
	for _, it := range s.iterators {
		r := it.Range()
		its = append(its, hqtrace.M{"lo": r.InclusiveMin.TaskID, "hi": r.ExclusiveMax.TaskID})
	}
	for _, e := range s.pendingExecutables {
		tr = append(tr, hqtrace.Ptr(e))
	}
	slices.Sort(tr)
	counts := map[string]int{}
	for key, n := range s.pendingPerKey {
		counts[key.(string)] = n
	}
	return hqtrace.M{"address": hqtrace.Ptr(z), "scope": hqScope(s.scope), "iters": its, "tracked": tr, "pending_per_key": counts}
}
