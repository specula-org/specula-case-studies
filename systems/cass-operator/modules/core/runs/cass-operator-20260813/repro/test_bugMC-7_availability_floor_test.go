// Reproduction for finding MC-7:
//   "Availability floor breached during the scale-up / PDB-recreate window"
//   Invariant AvailabilityFloor: (ready_pods - evicted_pods) >= (desired_size - 1)
//   Counterexample: spec/output/MC_hunt_scenario4.out
//   Upstream (KNOWN, unfixed): https://github.com/k8ssandra/cass-operator/issues/741
//
// This is a Level-0 reproduction driven entirely through the operator's real
// reconcile entry points (CheckRackScale / CheckDcPodDisruptionBudget) and its
// real PDB constructor (newPodDisruptionBudgetForDatacenter). It reproduces the
// exact MC trace:
//
//   State2  S4_ChangeDatacenterSize : dc.Spec.Size 2 -> 3
//   State*  S4_CheckRackScale       : rc.CheckRackScale() scales the STS to 3
//                                     BUT the PDB minAvailable stays stale at 1
//                                     (CheckDcPodDisruptionBudget runs later in
//                                      the ladder, reconcile_racks.go:2810<2830,
//                                      and is gated behind CheckPodsReady:2814)
//   State3  S4_AdmitVoluntaryEviction: an external voluntary eviction is admitted
//                                     against the stale PDB, dropping live
//                                     availability below the Size-1 floor.
//
// The eviction-admission decision is evaluated with the exact, documented
// Kubernetes PDB rule used by the API server:
//   disruptionsAllowed = currentHealthy - desiredHealthy   (desiredHealthy = minAvailable)
//   an eviction is admitted iff disruptionsAllowed >= 1
// (kube disruption controller sets Status.DisruptionsAllowed; the /eviction
//  subresource's checkAndDecrement admits iff DisruptionsAllowed >= 1).
//
// To run (must be inside the cass-operator module so it links the real code):
//   cp test_bugMC-7_availability_floor_test.go <worktree>/pkg/reconciliation/zz_bug_mc7_repro_test.go
//   cd <worktree> && go test ./pkg/reconciliation/ -run TestSpeculaBugMC7AvailabilityFloor -v
// The accompanying test_bugMC-7_run.sh does exactly this and cleans up.

package reconciliation

import (
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	policyv1 "k8s.io/api/policy/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	"github.com/stretchr/testify/require"
)

// evictionAdmitted models the Kubernetes API-server voluntary-eviction admission
// rule for a minAvailable PodDisruptionBudget: the disruption controller sets
// DisruptionsAllowed = currentHealthy - desiredHealthy (desiredHealthy == minAvailable),
// and the /eviction subresource admits the request iff DisruptionsAllowed >= 1.
func evictionAdmitted(currentHealthy, minAvailable int) bool {
	disruptionsAllowed := currentHealthy - minAvailable
	return disruptionsAllowed >= 1
}

func TestSpeculaBugMC7AvailabilityFloor(t *testing.T) {
	require := require.New(t)
	rc, _, cleanup := setupTest()
	defer cleanup()

	const oldSize = int32(2)
	const newSize = int32(3)

	// ---- Initial cluster: Size=2, STS replicas=2, 2 ready pods, PDB minAvailable=1 (Size-1).
	sts, err := newStatefulSetForCassandraDatacenter(nil, "default", rc.Datacenter, int(oldSize), rc.ImageRegistry)
	require.NoError(err)
	oldPDB := newPodDisruptionBudgetForDatacenter(rc.Datacenter) // Size=2 -> minAvailable=1
	pods := []*corev1.Pod{
		{ObjectMeta: metav1.ObjectMeta{Name: "mc7-0", Namespace: rc.Datacenter.Namespace}},
		{ObjectMeta: metav1.ObjectMeta{Name: "mc7-1", Namespace: rc.Datacenter.Namespace}},
	}
	objects := []runtime.Object{rc.Datacenter, sts, oldPDB, pods[0], pods[1]}
	rc.Client = fake.NewClientBuilder().
		WithScheme(setupScheme()).
		WithStatusSubresource(rc.Datacenter, pods[0], pods[1]).
		WithRuntimeObjects(objects...).
		WithIndex(&corev1.Pod{}, podPVCClaimNameField, podPVCClaimNames).
		Build()
	rc.desiredRackInformation = []*RackInformation{{RackName: "default", NodeCount: int(newSize)}}
	rc.statefulSets = []*appsv1.StatefulSet{sts}

	readyPods := 2 // both initial pods are Ready; the 3rd (scaled) pod is not yet scheduled/ready

	require.Equal(int(oldSize-1), oldPDB.Spec.MinAvailable.IntValue(),
		"precondition: PDB minAvailable is Size-1 for the old size")
	t.Logf("State1  init                : Size=%d stsReplicas=%d readyPods=%d PDB.minAvailable=%d  floor(Size-1)=%d",
		oldSize, oldSize, readyPods, oldPDB.Spec.MinAvailable.IntValue(), oldSize-1)

	// ---- State2  S4_ChangeDatacenterSize : scale-up requested, Size 2 -> 3.
	rc.Datacenter.Spec.Size = newSize
	require.NoError(rc.Client.Update(rc.Ctx, rc.Datacenter))
	t.Logf("State2  ChangeDatacenterSize : Spec.Size %d -> %d (voluntary floor is now newSize-1=%d)",
		oldSize, newSize, newSize-1)

	// ---- S4_CheckRackScale : the operator scales the STS to the new size FIRST
	//      (reconcile_racks.go:2810). The PDB step (:2830) has not run yet.
	res := rc.CheckRackScale()
	require.False(res.Completed(), "CheckRackScale returns Continue(), so the same reconcile proceeds toward CheckPodsReady/CheckDcPodDisruptionBudget")
	scaledSts := &appsv1.StatefulSet{}
	require.NoError(rc.Client.Get(rc.Ctx, types.NamespacedName{Name: sts.Name, Namespace: sts.Namespace}, scaledSts))
	require.Equal(newSize, *scaledSts.Spec.Replicas, "CheckRackScale must have scaled the STS to the new size")

	// ---- Observe the live PDB during the window: it is STILL stale (minAvailable=1).
	stalePDB := &policyv1.PodDisruptionBudget{}
	require.NoError(rc.Client.Get(rc.Ctx,
		types.NamespacedName{Name: rc.Datacenter.Name + "-pdb", Namespace: rc.Datacenter.Namespace}, stalePDB))
	staleMinAvail := stalePDB.Spec.MinAvailable.IntValue()
	t.Logf("        CheckRackScale       : stsReplicas -> %d, but live PDB.minAvailable is STILL %d (STALE; correct=%d)",
		*scaledSts.Spec.Replicas, staleMinAvail, newSize-1)
	require.Equal(int(oldSize-1), staleMinAvail,
		"BUG: after scale-up the PDB minAvailable is still the OLD Size-1 (stale window)")

	// ---- State3  S4_AdmitVoluntaryEviction : an external node drain/eviction hits the window.
	//      The API server admits it against the stale PDB.
	admittedStale := evictionAdmitted(readyPods, staleMinAvail) // 2 - 1 = 1 >= 1 -> ADMITTED
	t.Logf("State3  AdmitVoluntaryEviction: currentHealthy=%d staleMinAvailable=%d -> disruptionsAllowed=%d -> admitted=%v",
		readyPods, staleMinAvail, readyPods-staleMinAvail, admittedStale)
	require.True(admittedStale, "the stale PDB admits the voluntary eviction")

	evicted := 0
	if admittedStale {
		evicted = 1
	}
	liveAvailability := readyPods - evicted // ready - evicted
	floor := int(newSize) - 1              // desired_size - 1

	// ---- Invariant AvailabilityFloor: (ready - evicted) >= (desired_size - 1)
	floorHolds := liveAvailability >= floor
	t.Logf("        AvailabilityFloor    : (ready-evicted)=%d  >=  (desired_size-1)=%d  ?  %v",
		liveAvailability, floor, floorHolds)

	// ---- Causation: with the CORRECT (in-lockstep) PDB the eviction is BLOCKED.
	rc.Datacenter.Spec.Size = newSize
	correctPDB := newPodDisruptionBudgetForDatacenter(rc.Datacenter) // Size=3 -> minAvailable=2
	correctMinAvail := correctPDB.Spec.MinAvailable.IntValue()
	admittedCorrect := evictionAdmitted(readyPods, correctMinAvail) // 2 - 2 = 0 -> BLOCKED
	t.Logf("        (control) correct PDB: minAvailable=%d -> disruptionsAllowed=%d -> admitted=%v (would PROTECT the floor)",
		correctMinAvail, readyPods-correctMinAvail, admittedCorrect)

	if floorHolds {
		t.Fatalf("BUG NOT REPRODUCED: AvailabilityFloor still holds (%d >= %d)", liveAvailability, floor)
	}
	require.False(admittedCorrect,
		"causation: an in-lockstep PDB (minAvailable=%d) would have BLOCKED the eviction", correctMinAvail)

	t.Logf("==> BUG MC-7 REPRODUCED: scale-up left PDB.minAvailable stale at %d; a voluntary eviction was admitted, "+
		"dropping live availability to %d, BELOW the Size-1 floor of %d (AvailabilityFloor VIOLATED). "+
		"An in-lockstep PDB (minAvailable=%d) would have blocked it. Matches MC_hunt_scenario4.out and upstream #741.",
		staleMinAvail, liveAvailability, floor, correctMinAvail)
}
