package reconciliation

// Reproduction for finding MC-3:
// "Capacity check bypassed when per-pod load is missing"
//
// EnsurePodsCanAbsorbDecommData reads spaceUsedByDecommPod from a Go map
// (podsUsedStorage[decommPod.Name]). When the decommission target is absent from the
// mgmt-API endpoint (gossip) snapshot, that read defaults to 0, so the guard
// `free < spaceUsedByDecommPod` becomes `free < 0`, which is never true. The scale-down
// is approved even though the leaving node's load is unknown and may exceed the free
// space on the remaining node(s).
//
// This maps to MC counterexample spec/output/MC_hunt_scenario2_capacity.out, State 2:
//   s2.load_known = FALSE  AND  s2.capacity_approved = TRUE  (invariant CapacityRespected violated)
//
// Escalation level: 0/1 (real mgmt-API path + public method; no source patch, no
// unreachable hand-built state). The "target missing from the snapshot" precondition is
// produced by the real fake mgmt-API server (ring.set(..., includeTarget=false)), exactly
// as the existing scenario2-metadata-partial test drives it.

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/k8ssandra/cass-operator/pkg/httphelper"
)

func TestBugMC3CapacityBypassMissingLoad(t *testing.T) {
	fixture := speculaNewDecommissionFixture(t)

	// The peer's server-data PVC has capacity "100" (see speculaNewDecommissionFixture);
	// the peer reports load "5". So the peer's real free space is 95 units.
	const peerFreeSpace = int64(100 - 5)

	// --- Level 0: the missing-target snapshot is produced by the REAL mgmt API ---
	// Drive the fake mgmt-API server so the ring/gossip snapshot omits the decommission
	// target (a node that just (re)started / has not converged in gossip). This is the
	// same knob the existing scenario2-metadata-partial test uses.
	fixture.ring.set(string(httphelper.StatusNormal), false)

	epsMissing := fixture.rc.getCassMetadataEndpoints()
	mapped := MapPodsToEndpointDataByName(fixture.rc.dcPods, epsMissing)
	if _, ok := mapped[fixture.target.Name]; ok {
		t.Fatalf("precondition not set up: decomm target %q unexpectedly present in mgmt-API snapshot", fixture.target.Name)
	}
	if _, ok := mapped[fixture.peer.Name]; !ok {
		t.Fatalf("precondition not set up: peer %q missing from mgmt-API snapshot", fixture.peer.Name)
	}
	t.Logf("Level 0: real mgmt-API snapshot has %d endpoint(s); decomm target %q is ABSENT (load unknown), peer %q present",
		len(epsMissing.Entity), fixture.target.Name, fixture.peer.Name)

	// --- The bug: capacity approved despite the target's load being unknown ---
	errMissing := fixture.rc.EnsurePodsCanAbsorbDecommData(fixture.target, epsMissing)

	// --- Control: if the target's (large) load WERE observed, the guard fires correctly ---
	// Build the same snapshot but with the target present reporting a load of 200 units,
	// i.e. more than the peer's 95 units of free space. Everything else (peer capacity 100,
	// peer load 5) is identical to the missing case; only the target's load visibility
	// changes. A value the mgmt API could legitimately return if the target were in gossip.
	const targetRealLoad = int64(200)
	epsKnown := httphelper.CassMetadataEndpoints{Entity: append([]httphelper.EndpointState{}, epsMissing.Entity...)}
	epsKnown.Entity = append(epsKnown.Entity, httphelper.EndpointState{
		RpcAddress: fixture.target.Status.PodIP,
		EndpointIP: fixture.target.Status.PodIP,
		HostID:     "target-host",
		Status:     string(httphelper.StatusNormal),
		IsAlive:    "true",
		Load:       "200",
	})
	// Sanity: with the target present, the operator now sees it.
	mappedKnown := MapPodsToEndpointDataByName(fixture.rc.dcPods, epsKnown)
	if _, ok := mappedKnown[fixture.target.Name]; !ok {
		t.Fatalf("control set-up failed: target still absent after adding its endpoint")
	}
	errKnown := fixture.rc.EnsurePodsCanAbsorbDecommData(fixture.target, epsKnown)

	t.Logf("peer free space = %d units; target real load = %d units (%d > %d, so the decommission is genuinely over-capacity)",
		peerFreeSpace, targetRealLoad, targetRealLoad, peerFreeSpace)
	t.Logf("load MISSING  -> EnsurePodsCanAbsorbDecommData = %v  (nil means APPROVED)", errMissing)
	t.Logf("load OBSERVED -> EnsurePodsCanAbsorbDecommData = %v  (non-nil means REJECTED)", errKnown)

	// The control MUST reject: this proves the over-capacity scale-down is genuinely unsafe
	// and that the guard works when the load is visible.
	require.Error(t, errKnown, "control: with the load observed, the over-capacity decommission must be rejected")

	// The bug: with the identical physical reality but the target's load merely UNOBSERVED,
	// the guard is bypassed and the same unsafe decommission is APPROVED.
	if errMissing == nil {
		t.Logf("BUG MC-3 REPRODUCED: capacity guard BYPASSED when the decomm pod's load is missing "+
			"from the mgmt-API snapshot. spaceUsedByDecommPod defaulted to 0, so `free(%d) < 0` was false "+
			"and the over-capacity decommission (target load %d > peer free %d) was approved.",
			peerFreeSpace, targetRealLoad, peerFreeSpace)
	} else {
		t.Fatalf("BUG NOT REPRODUCED: missing-load path returned an error (%v); the guard was not bypassed", errMissing)
	}

	// Assert the anomaly precisely: approved-when-missing vs rejected-when-observed.
	require.NoError(t, errMissing,
		"MC-3: missing decomm-pod load must (buggily) be approved; if this now errors, the bug is fixed")
}
