package reconciliation_test

// Reproduction for finding MC-8:
// "Finalizer deadlock - DC stuck Terminating when a required secret is deleted first".
//
// Mechanism (all in the REAL Reconcile entry point):
//   Reconcile() -> rc.IsValid() runs FIRST (cassandradatacenter_controller.go:133).
//   IsValid -> validateSuperuserSecret errors when a USER-PROVIDED superuser secret
//   is NotFound (secrets.go:275-292, only when !ShouldGenerateSuperuserSecret()).
//   On that error Reconcile returns reconcile.TerminalError (no requeue).
//   ProcessDeletion (which clears the operator finalizer, reconcile_datacenter.go:133)
//   lives inside CalculateReconciliationActions (handler.go:51) reached only AFTER
//   IsValid passes. So if the secret is deleted before the DC, a DC with a
//   deletionTimestamp can never pass validation -> finalizer never removed ->
//   DC stuck Terminating forever (#952 / #812).
//
// This is a Level-0 black-box reproduction: it uses only the public Reconcile
// entry point and a normal `kubectl delete` (fake client Delete with a finalizer
// present), no failpoints and no source modification.

import (
	"context"
	"path/filepath"
	"testing"

	api "github.com/k8ssandra/cass-operator/apis/cassandra/v1beta1"
	"github.com/k8ssandra/cass-operator/pkg/events"
	"github.com/stretchr/testify/require"

	controllers "github.com/k8ssandra/cass-operator/internal/controllers/cassandra"
	"github.com/k8ssandra/cass-operator/pkg/dynamicwatch"
	"github.com/k8ssandra/cass-operator/pkg/images"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	record "k8s.io/client-go/tools/events"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

func mc8Scheme() *runtime.Scheme {
	s := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(s)
	_ = api.AddToScheme(s)
	return s
}

func mc8DC(name, namespace string) *api.CassandraDatacenter {
	storageSize := resource.MustParse("1Gi")
	storageName := "server-data"
	return &api.CassandraDatacenter{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
			// The operator finalizer is already present (normal steady state).
			Finalizers: []string{api.Finalizer},
		},
		Spec: api.CassandraDatacenterSpec{
			ManagementApiAuth: api.ManagementApiAuthConfig{
				Insecure: &api.ManagementApiAuthInsecureConfig{},
			},
			Size:          2,
			ServerType:    "cassandra",
			ServerVersion: "4.1.4",
			ClusterName:   "cluster1",
			// USER-PROVIDED superuser secret => ShouldGenerateSuperuserSecret()==false
			// => the operator will NOT regenerate it if it goes missing.
			SuperuserSecretName: "my-superuser",
			StorageConfig: api.StorageConfig{
				CassandraDataVolumeClaimSpec: &corev1.PersistentVolumeClaimSpec{
					StorageClassName: &storageName,
					AccessModes:      []corev1.PersistentVolumeAccessMode{"ReadWriteOnce"},
					Resources: corev1.VolumeResourceRequirements{
						Requests: map[corev1.ResourceName]resource.Quantity{"storage": storageSize},
					},
				},
			},
		},
	}
}

func TestBugMC8_FinalizerDeadlockOnSecretDeletedFirst(t *testing.T) {
	ctx := context.Background()
	name, namespace := "dc1", "default"
	s := mc8Scheme()

	dc := mc8DC(name, namespace)

	fc := fake.NewClientBuilder().
		WithScheme(s).
		WithStatusSubresource(&api.CassandraDatacenter{}).
		WithObjects(dc).
		Build()

	// Step 1 (real op): `kubectl delete cassandradatacenter dc1`.
	// The operator finalizer is present, so the object is NOT removed: it gets a
	// deletionTimestamp and enters the "Terminating" state.
	require.NoError(t, fc.Delete(ctx, mc8DC(name, namespace)))

	stored := &api.CassandraDatacenter{}
	require.NoError(t, fc.Get(ctx, types.NamespacedName{Name: name, Namespace: namespace}, stored))
	require.NotNil(t, stored.GetDeletionTimestamp(), "precondition: DC is Terminating")
	require.True(t, controllerutil.ContainsFinalizer(stored, api.Finalizer), "precondition: operator finalizer present")

	// Step 2 (real op): the user-provided superuser secret "my-superuser" was
	// deleted FIRST -- it never exists in the API server (matches CE step
	// MCDeleteDependencySecret: dependency_present=FALSE).

	r := &controllers.CassandraDatacenterReconciler{Client: fc, Scheme: s}
	r.Recorder = events.NewLoggingEventRecorder(record.NewFakeRecorder(100), r.Log.WithName("mc8"))
	// SecretWatches and ImageRegistry are only consulted on the successful
	// deletion/cleanup path (ProcessDeletion: removing dynamic watches and building
	// the StatefulSet to scale it to 0). They are NOT needed to trigger the
	// deadlock; they are wired here so the causation control below can run to
	// completion (the same wiring the envtests use).
	r.SecretWatches = dynamicwatch.NewDynamicSecretWatches(fc)
	registry, regErr := images.NewImageRegistry(filepath.Join("..", "..", "tests", "testdata", "image_config_parsing.yaml"))
	require.NoError(t, regErr)
	r.ImageRegistry = registry
	request := reconcile.Request{NamespacedName: types.NamespacedName{Name: name, Namespace: namespace}}

	// Step 3: the operator reconciles the deletion repeatedly (simulating repeated
	// watch-driven wakeups). Each pass hits IsValid -> TerminalError -> no requeue,
	// and ProcessDeletion is never reached, so the finalizer is never removed.
	for i := 1; i <= 3; i++ {
		result, err := r.Reconcile(ctx, request)
		require.Errorf(t, err, "attempt %d: IsValid must fail because the superuser secret is gone", i)
		require.Containsf(t, err.Error(), "superuser secret",
			"attempt %d: the blocking error is the missing superuser secret; got: %v", i, err)
		require.Equalf(t, reconcile.Result{}, result, "attempt %d: TerminalError => no requeue", i)

		cur := &api.CassandraDatacenter{}
		require.NoError(t, fc.Get(ctx, request.NamespacedName, cur))
		require.Truef(t, controllerutil.ContainsFinalizer(cur, api.Finalizer),
			"BUG REPRODUCED: attempt %d: operator finalizer never removed -> DC stuck Terminating", i)
		require.NotNil(t, cur.GetDeletionTimestamp(), "attempt %d: DC still Terminating", i)
	}
	t.Logf("BUG REPRODUCED: after 3 reconciles the DC %q is still Terminating with finalizer %q; it can never be deleted.",
		name, api.Finalizer)

	// Control (causation): restore the user-provided superuser secret, then
	// reconcile once more. Now IsValid passes, ProcessDeletion runs and clears the
	// finalizer, and the DC is finally deleted. This proves the missing secret is
	// the SOLE cause of the deadlock (delete/cleanup path exercised end-to-end).
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "my-superuser", Namespace: namespace},
		Data: map[string][]byte{
			"username": []byte("cassandra-admin"),
			"password": []byte("s3cr3t-p4ss"),
		},
	}
	require.NoError(t, fc.Create(ctx, secret))

	_, err := r.Reconcile(ctx, request)
	require.NoError(t, err, "control: with the secret restored IsValid passes and ProcessDeletion runs")

	gone := &api.CassandraDatacenter{}
	getErr := fc.Get(ctx, request.NamespacedName, gone)
	require.Truef(t, apierrors.IsNotFound(getErr),
		"control: once the secret exists the finalizer is removed and the DC is deleted; got err=%v", getErr)
	t.Log("CONTROL PASSED: restoring the superuser secret let the finalizer be removed -> the missing secret is the sole cause.")
}
