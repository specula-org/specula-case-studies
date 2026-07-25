#!/usr/bin/env bash
# Build and run the three bug reproduction tests.
# Requires the libspdm libraries to have been built first in build/tla_trace/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBSPDM="$ROOT/artifact/libspdm"
BUILD="$ROOT/build/tla_trace"
REPRO="$ROOT/repro"
BIN="$REPRO/bin"

mkdir -p "$BIN"

DEFINES="-DLIBSPDM_AEAD_SM4_128_GCM_SUPPORT=0 \
         -DLIBSPDM_EDDSA_ED25519_SUPPORT=0 \
         -DLIBSPDM_EDDSA_ED448_SUPPORT=0 \
         -DLIBSPDM_ML_DSA_44_SUPPORT=0 \
         -DLIBSPDM_ML_DSA_65_SUPPORT=0 \
         -DLIBSPDM_ML_DSA_87_SUPPORT=0 \
         -DLIBSPDM_ML_KEM_1024_SUPPORT=0 \
         -DLIBSPDM_ML_KEM_512_SUPPORT=0 \
         -DLIBSPDM_ML_KEM_768_SUPPORT=0 \
         -DLIBSPDM_SLH_DSA_SHA2_128F_SUPPORT=0 \
         -DLIBSPDM_SLH_DSA_SHA2_128S_SUPPORT=0 \
         -DLIBSPDM_SLH_DSA_SHA2_192F_SUPPORT=0 \
         -DLIBSPDM_SLH_DSA_SHA2_192S_SUPPORT=0 \
         -DLIBSPDM_SLH_DSA_SHA2_256F_SUPPORT=0 \
         -DLIBSPDM_SLH_DSA_SHA2_256S_SUPPORT=0 \
         -DLIBSPDM_SLH_DSA_SHAKE_128F_SUPPORT=0 \
         -DLIBSPDM_SLH_DSA_SHAKE_128S_SUPPORT=0 \
         -DLIBSPDM_SLH_DSA_SHAKE_192F_SUPPORT=0 \
         -DLIBSPDM_SLH_DSA_SHAKE_192S_SUPPORT=0 \
         -DLIBSPDM_SLH_DSA_SHAKE_256F_SUPPORT=0 \
         -DLIBSPDM_SLH_DSA_SHAKE_256S_SUPPORT=0 \
         -DLIBSPDM_SM2_DSA_P256_SUPPORT=0 \
         -DLIBSPDM_SM2_KEY_EXCHANGE_P256_SUPPORT=0 \
         -DLIBSPDM_SM3_256_SUPPORT=0"

FLAGS="-O0 -std=c99 -fshort-wchar -fno-strict-aliasing \
       -Wno-array-bounds -ffunction-sections -fdata-sections -fno-common \
       -Wno-address -fpie -fno-asynchronous-unwind-tables \
       -Wno-maybe-uninitialized -Wno-uninitialized \
       -Wno-builtin-declaration-mismatch -Wno-nonnull-compare \
       -Wcast-qual -mno-red-zone -maccumulate-outgoing-args -g -flto -m64 -mcmodel=small"

LINK_FLAGS="-flto -Wno-error -no-pie"

INCLUDES="-I$LIBSPDM/include \
          -I$LIBSPDM/unit_test/include \
          -I$LIBSPDM/unit_test/spdm_unit_test_common \
          -I$LIBSPDM/os_stub/spdm_device_secret_lib_sample \
          -I$LIBSPDM/os_stub"

LIBS="$BUILD/lib/libmemlib.a \
      $BUILD/lib/libdebuglib.a \
      $BUILD/lib/libspdm_responder_lib.a \
      $BUILD/lib/libspdm_requester_lib.a \
      $BUILD/lib/libspdm_common_lib.a \
      $BUILD/lib/librnglib.a \
      $BUILD/lib/libcryptlib_mbedtls.a \
      $BUILD/lib/libmalloclib.a \
      $BUILD/lib/libspdm_crypt_lib.a \
      $BUILD/lib/libspdm_crypt_ext_lib.a \
      $BUILD/lib/libspdm_secured_message_lib.a \
      $BUILD/lib/libspdm_device_secret_lib_sample.a \
      $BUILD/lib/libspdm_transport_test_lib.a \
      $BUILD/lib/libplatform_lib.a \
      $BUILD/lib/libmbedx509.a \
      $BUILD/lib/libmbedcrypto.a"

SUPPORT_OBJ="$BUILD/unit_test/test_vca_trace/CMakeFiles/test_vca_trace.dir/__/spdm_unit_test_common/support.c.o"

compile_and_run() {
    local src="$1"
    local name="$(basename "$src" .c)"
    local bin="$BIN/$name"

    echo "--- Building $name ---"
    gcc $DEFINES $FLAGS $INCLUDES $LINK_FLAGS -o "$bin" "$src" "$SUPPORT_OBJ" \
        -Wl,--start-group $LIBS -Wl,--end-group
    echo "--- Running $name ---"
    "$bin"
    local rc=$?
    echo ""
    return $rc
}

overall=0

compile_and_run "$REPRO/test_bug_f4_transcript.c" || overall=1
compile_and_run "$REPRO/test_bug_f2_rsp_flags.c" || overall=1
compile_and_run "$REPRO/test_bug_f1_asym_no_cap.c" || overall=1

if [ $overall -eq 0 ]; then
    echo "=== All three bugs confirmed ==="
else
    echo "=== Some bugs could not be confirmed — see output above ==="
fi
exit $overall
