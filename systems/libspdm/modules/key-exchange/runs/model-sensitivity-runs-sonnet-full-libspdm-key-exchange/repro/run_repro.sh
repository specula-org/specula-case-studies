#!/bin/bash
# Reproduction runner for libspdm KEY_EXCHANGE / FINISH bugs.
# Must be run from: /home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/libspdm-key-exchange/repro/
# Requires the pre-built libraries in ../artifact/libspdm/build_trace/lib/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT="${SCRIPT_DIR}/../artifact/libspdm"
BUILD="${ARTIFACT}/build_trace"
LIB="${BUILD}/lib"
BIN="${SCRIPT_DIR}/bin"
CERT_DIR="${BUILD}/bin"  # certs are copied here by cmake

INCLUDES="-I${ARTIFACT}/include \
          -I${ARTIFACT}/unit_test/include \
          -I${ARTIFACT}/unit_test/spdm_unit_test_common \
          -I${ARTIFACT}/os_stub/spdm_device_secret_lib_sample \
          -I${ARTIFACT}/os_stub"

TLA_GLOBALS="${ARTIFACT}/unit_test/test_tla_trace/tla_trace_globals.c"

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
         -DLIBSPDM_SM3_256_SUPPORT=0 \
         -DTLA_TRACE_ENABLED=1 \
         -D_POSIX_C_SOURCE=200809L"

CFLAGS="-O0 -std=c99 -fshort-wchar -fno-strict-aliasing -Wall \
        -Wno-array-bounds -ffunction-sections -fdata-sections -fno-common \
        -Wno-address -fpie -fno-asynchronous-unwind-tables \
        -Wno-maybe-uninitialized -Wno-uninitialized \
        -Wno-builtin-declaration-mismatch -Wno-nonnull-compare \
        -mno-red-zone -maccumulate-outgoing-args -g -m64 -mcmodel=small \
        -Wno-unused-function -Wno-unused-variable -Wno-pedantic -Wno-implicit-function-declaration"

# Support object (read_input_file etc.)
SUPPORT="${ARTIFACT}/unit_test/spdm_unit_test_common/support.c"

LIBS="-Wl,--start-group \
      ${LIB}/libmemlib.a \
      ${LIB}/libdebuglib.a \
      ${LIB}/libspdm_responder_lib.a \
      ${LIB}/libspdm_requester_lib.a \
      ${LIB}/libspdm_common_lib.a \
      ${LIB}/librnglib.a \
      ${LIB}/libcryptlib_mbedtls.a \
      ${LIB}/libmalloclib.a \
      ${LIB}/libspdm_crypt_lib.a \
      ${LIB}/libspdm_crypt_ext_lib.a \
      ${LIB}/libspdm_secured_message_lib.a \
      ${LIB}/libspdm_device_secret_lib_sample.a \
      ${LIB}/libspdm_transport_test_lib.a \
      ${LIB}/libplatform_lib.a \
      ${LIB}/libmbedx509.a \
      ${LIB}/libmbedcrypto.a \
      -Wl,--end-group"

mkdir -p "${BIN}"

echo "========================================================"
echo " Building reproduction tests"
echo "========================================================"

# BUG-001: HITC Session Identity Confusion (Level 0)
echo ""
echo "[BUG-001] Building test_bug1_hitc_session_confusion..."
gcc $CFLAGS $DEFINES $INCLUDES \
    "${SCRIPT_DIR}/test_bug1_hitc_session_confusion.c" \
    "$SUPPORT" "$TLA_GLOBALS" \
    -o "${BIN}/test_bug1" \
    -flto -Wno-error -no-pie \
    $LIBS
echo "  Built: ${BIN}/test_bug1"

# BUG-002: Non-Encap Cert Slot (Level 3 — custom callback)
# Note: does NOT link libspdm_device_secret_lib_sample.a for key_ex symbols;
# instead provides its own libspdm_key_exchange_start_mut_auth in test_bug2.c.
echo ""
echo "[BUG-002] Building test_bug2_nonencap_cert_slot..."
gcc $CFLAGS $DEFINES $INCLUDES \
    "${SCRIPT_DIR}/test_bug2_nonencap_cert_slot.c" \
    "$SUPPORT" "$TLA_GLOBALS" \
    -o "${BIN}/test_bug2" \
    -flto -Wno-error -no-pie \
    -Wl,--allow-multiple-definition \
    $LIBS
echo "  Built: ${BIN}/test_bug2"

# BUG-003: Session Slot Leak (Level 3 — --wrap=libspdm_calculate_th2_hash)
echo ""
echo "[BUG-003] Building test_bug3_session_slot_leak..."
# The pre-built .a files embed GIMPLE IR (built with -flto). The LTO plugin inlines
# libspdm_calculate_th2_hash into libspdm_rsp_finish_rsp at link time, making --wrap
# ineffective. Fix: recompile libspdm_rsp_finish_rsp.c WITHOUT -flto so its object file
# contains machine code with a real CALL instruction that --wrap can intercept.
FINISH_RSP_SRC="${ARTIFACT}/library/spdm_responder_lib/libspdm_rsp_finish_rsp.c"
FINISH_RSP_OBJ="${BIN}/libspdm_rsp_finish_rsp_nolto.o"
gcc $DEFINES $INCLUDES \
    -O0 -std=c99 -fshort-wchar -fno-strict-aliasing -Wall \
    -Wno-array-bounds -ffunction-sections -fdata-sections -fno-common \
    -Wno-address -fpie -fno-asynchronous-unwind-tables \
    -Wno-maybe-uninitialized -Wno-uninitialized \
    -Wno-builtin-declaration-mismatch -Wno-nonnull-compare \
    -mno-red-zone -maccumulate-outgoing-args -g -m64 -mcmodel=small \
    -fno-lto \
    -c "$FINISH_RSP_SRC" -o "$FINISH_RSP_OBJ"
echo "  Compiled: $FINISH_RSP_OBJ (no LTO)"
gcc $CFLAGS $DEFINES $INCLUDES \
    "${SCRIPT_DIR}/test_bug3_session_slot_leak.c" \
    "$SUPPORT" "$TLA_GLOBALS" \
    "$FINISH_RSP_OBJ" \
    -o "${BIN}/test_bug3" \
    -Wno-error -no-pie \
    -Wl,--wrap=libspdm_calculate_th2_hash \
    -Wl,--allow-multiple-definition \
    $LIBS
echo "  Built: ${BIN}/test_bug3"

# BUG-004: Seq Counter Before AEAD (Level 0)
echo ""
echo "[BUG-004] Building test_bug4_seq_counter_before_aead..."
gcc $CFLAGS $DEFINES $INCLUDES \
    "${SCRIPT_DIR}/test_bug4_seq_counter_before_aead.c" \
    "$SUPPORT" "$TLA_GLOBALS" \
    -o "${BIN}/test_bug4" \
    -flto -Wno-error -no-pie \
    $LIBS
echo "  Built: ${BIN}/test_bug4"

echo ""
echo "========================================================"
echo " Running reproduction tests"
echo " (certs from ${CERT_DIR}/ecp256)"
echo "========================================================"

# Must run from a directory containing cert files (same as trace_test)
cd "${CERT_DIR}"

run_test() {
    local name="$1"
    local bin="$2"
    echo ""
    echo "--- ${name} ---"
    timeout 60s "${bin}" 2>&1
    local rc=$?
    if [ $rc -eq 124 ]; then
        echo "TIMEOUT: test killed after 60s"
    fi
    echo "(exit code: $rc)"
}

run_test "BUG-001: HITC Session Identity Confusion"   "${BIN}/test_bug1"
run_test "BUG-002: Non-Encap Cert Slot Not Stored"    "${BIN}/test_bug2"
run_test "BUG-003: Session Slot Leak on TH2 Failure"  "${BIN}/test_bug3"
run_test "BUG-004: Seq Counter Before AEAD"           "${BIN}/test_bug4"

echo ""
echo "========================================================"
echo " All reproduction tests complete"
echo "========================================================"
