//go:build specula
// +build specula

package tracker

// SpeculaInflights copies the logical ring order without changing its state.
// The caller holds the Raft serialization boundary.
func (in *Inflights) SpeculaInflights() []uint64 {
	result := make([]uint64, in.count)
	for k := range result {
		result[k] = in.buffer[(in.start+k)%in.size]
	}
	return result
}
