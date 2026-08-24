package reconciliation

// Reproduction for finding MC-1:
// "Cross-epoch PVC deletion via name-based matching + stale cache"
//
// deletePVCs() (pkg/reconciliation/reconcile_datacenter.go:147-200) selects PVCs
// purely by rc.Datacenter.GetDatacenterLabels() -- name-based cluster/datacenter
// labels (apis/.../cassandradatacenter_types.go:640) -- and gates each delete ONLY
// on the isBeingUsed() pod-mount check (:179-184, :202-218). There is NO
// ownerReference/UID/generation guard, and STS-template PVCs are not owner-referenced
// to the DC generation (construct_statefulset.go:97-104).
//
// When the operator holds a STALE deleting view of DC generation "epoch-a" (its
// cached CassandraDatacenter still carries a deletionTimestamp) while an
// identically-named generation "epoch-b" has already been recreated with a different
// UID, deletePVCs() lists epoch-b's live data PVC (same name-based labels) and, once
// the pod-mount check passes, deletes it -- destroying the live datacenter's data.
//
// This maps to MC counterexample spec/output/MC_hunt_scenario1.out, State 8
// (action S1_ProcessDeletionDeletePVC, base.tla:305-314):
//     last_mutation_kind = "PVC"
//     last_mutation_actor  = cached_dc_epoch = "epoch-a"   (the stale deleting operator)
//     last_mutation_target = pvc_epoch       = "epoch-b"   (the live recreated PVC)
//   => invariant NoCrossEpochPVCDelete (actor == target) is violated.
//
// Known/unfixed upstream: k8ssandra/cass-operator issue #118 ("PVC can be deleted
// mistakenly when reading stale deletionTimestamp information", still OPEN) and its
// proposed fix PR #122 ("Check UID before deleting PVC", never merged). HEAD still
// lists PVCs by name-based labels with no UID guard.
//
// Escalation level: 2 (state injection). Level 0/1 cannot drive the DC informer cache
// stale-while-PVC-cache-current race deterministically (upstream #118 requires an
// apiserver partition + controller restart). The injected precondition -- rc.Datacenter
// is a stale epoch-a deleting view returned by the cached Get, while the fake client's
// PVC/pod caches hold the live epoch-b world -- is exactly what CreateReconciliationContext
// (context.go:82-97) produces under informer lag, and instantiates CE State 8 above.

import (
	"context"
	"testing"
	"time"

	"github.com/go-logr/logr"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	api "github.com/k8ssandra/cass-operator/apis/cassandra/v1beta1"
)

const (
	mc1EpochAUID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" // deleted generation "epoch-a"
	mc1EpochBUID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" // live recreated generation "epoch-b"
)

func TestBugMC1CrossEpochPVCDelete(t *testing.T) {
	// Base mock rc gives us a valid ReconciliationContext (logger, scheme, ctx, ...).
	rc := CreateMockReconciliationContext(logr.Discard())
	name := rc.Datacenter.Name
	namespace := rc.Datacenter.Namespace

	// --- The STALE deleting operator view: DC generation "epoch-a" ---------------
	// This is the object the cached Get returns under informer lag (context.go:82-87):
	// it still carries the finalizer + deletionTimestamp of the already-deleted epoch-a.
	staleEpochA := rc.Datacenter.DeepCopy()
	staleEpochA.UID = types.UID(mc1EpochAUID)
	staleEpochA.Finalizers = []string{api.Finalizer}
	delTime := metav1.NewTime(time.Now())
	staleEpochA.DeletionTimestamp = &delTime

	// --- The LIVE recreated world: DC generation "epoch-b" (different UID) --------
	liveEpochB := rc.Datacenter.DeepCopy()
	liveEpochB.UID = types.UID(mc1EpochBUID)
	liveEpochB.ResourceVersion = ""
	liveEpochB.Finalizers = nil
	liveEpochB.DeletionTimestamp = nil

	// epoch-b's live data PVC. Labeled with the SAME name-based GetDatacenterLabels()
	// (name+cluster identical across generations) and owner-referenced to the LIVE
	// epoch-b DC -- yet deletePVCs never inspects the owner/UID.
	livePVC := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      PvcName + "-" + name + "-default-sts-0",
			Namespace: namespace,
			UID:       types.UID(mc1EpochBUID),
			Labels:    liveEpochB.GetDatacenterLabels(),
			OwnerReferences: []metav1.OwnerReference{{
				APIVersion: "cassandra.datastax.com/v1beta1",
				Kind:       "CassandraDatacenter",
				Name:       liveEpochB.Name,
				UID:        types.UID(mc1EpochBUID),
			}},
		},
	}

	// epoch-b's live pod, mounting the live PVC (the datacenter is up and serving).
	livePod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name + "-default-sts-0",
			Namespace: namespace,
			UID:       types.UID(mc1EpochBUID),
			Labels:    liveEpochB.GetDatacenterLabels(),
		},
		Spec: corev1.PodSpec{
			Volumes: []corev1.Volume{{
				Name: "server-data",
				VolumeSource: corev1.VolumeSource{
					PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{
						ClaimName: livePVC.Name,
					},
				},
			}},
		},
	}

	rc.Client = fake.NewClientBuilder().
		WithScheme(setupScheme()).
		WithStatusSubresource(liveEpochB).
		WithRuntimeObjects(liveEpochB, livePVC, livePod).
		WithIndex(&corev1.Pod{}, podPVCClaimNameField, podPVCClaimNames).
		Build()

	// The operator acts on its STALE epoch-a view.
	rc.Datacenter = staleEpochA

	require.NotEqual(t, staleEpochA.UID, liveEpochB.UID,
		"precondition: the deleting operator's generation must differ from the live one")
	t.Logf("deleting operator sees stale DC %q UID=%s (deletionTimestamp set); live recreated DC %q UID=%s",
		staleEpochA.Name, staleEpochA.UID, liveEpochB.Name, liveEpochB.UID)

	// --- Guard active (isBeingUsed is the ONLY thing protecting the live PVC) -----
	// While epoch-b's pod still mounts the PVC, the sole guard rejects the delete.
	// This corresponds to CE States before the pod is removed.
	errWhileMounted := rc.deletePVCs()
	require.Error(t, errWhileMounted,
		"the only guard (isBeingUsed) should reject deletion while the live pod mounts the PVC")
	require.NoError(t, rc.Client.Get(context.Background(), client.ObjectKeyFromObject(livePVC),
		&corev1.PersistentVolumeClaim{}), "live PVC must still exist while its pod mounts it")
	t.Logf("Level-2 guard check: with live pod mounting the PVC, deletePVCs() correctly refused: %v", errWhileMounted)

	// --- CE State 6: the stale operator's scale-to-0 makes the STS controller ----
	// delete the epoch-b pod, releasing the PVC (pvc_in_use -> FALSE). We model that
	// real reaction by deleting the pod. Everything else is unchanged.
	require.NoError(t, rc.Client.Delete(context.Background(), livePod))

	// --- CE State 7->8: isBeingUsed now observes "not in use" and the stale ------
	// epoch-a operator deletes the LIVE epoch-b PVC. THE BUG.
	errAfterRelease := rc.deletePVCs()
	require.NoError(t, errAfterRelease, "deletePVCs returned an unexpected error")

	deleted := apierrors.IsNotFound(rc.Client.Get(context.Background(),
		client.ObjectKeyFromObject(livePVC), &corev1.PersistentVolumeClaim{}))

	if deleted {
		t.Logf("BUG MC-1 REPRODUCED: stale epoch-a operator (UID=%s) DELETED the live epoch-b "+
			"datacenter's data PVC %q (UID=%s, owned by live DC UID=%s). "+
			"NoCrossEpochPVCDelete violated: actor(epoch-a) != target(epoch-b). "+
			"With the default Delete reclaim policy this destroys the live datacenter's data permanently.",
			staleEpochA.UID, livePVC.Name, mc1EpochBUID, mc1EpochBUID)
	} else {
		t.Fatalf("BUG NOT REPRODUCED: live epoch-b PVC %q survived; a UID/owner guard must have blocked the cross-epoch delete", livePVC.Name)
	}

	// Assert the anomaly precisely: the live, different-generation PVC was destroyed
	// by an operator that believes it is deleting a different (already-gone) generation.
	require.True(t, deleted,
		"MC-1: the live epoch-b PVC must be (buggily) deleted by the stale epoch-a operator; "+
			"if it now survives, the name-based-without-UID defect (issue #118 / PR #122) is fixed")
}
