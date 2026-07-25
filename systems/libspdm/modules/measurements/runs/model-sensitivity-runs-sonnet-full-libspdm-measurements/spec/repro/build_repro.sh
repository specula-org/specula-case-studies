#!/usr/bin/env bash
# build_repro.sh — Build all bug reproduction tests.
# Run from this directory:  bash build_repro.sh
# OR from the libspdm-measurements directory: bash spec/repro/build_repro.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
ARTIFACT="${ROOT_DIR}/artifact/libspdm"
BUILD_DIR="${ARTIFACT}/build"
HARNESS_SRC="${ROOT_DIR}/harness/src"
LIB_DIR="${BUILD_DIR}/lib"
BIN_DIR="${BUILD_DIR}/bin"

echo "=== Building bug reproduction tests ==="
echo "ARTIFACT:   $ARTIFACT"
echo "HARNESS:    $HARNESS_SRC"
echo "LIB_DIR:    $LIB_DIR"
echo ""

CFLAGS="-O0 -g -std=c99 -fshort-wchar -fno-strict-aliasing \
    -Wall -Wno-error \
    -Wno-array-bounds \
    -Wno-maybe-uninitialized \
    -Wno-uninitialized \
    -Wno-builtin-declaration-mismatch \
    -fno-common -no-pie -flto -m64 \
    -DLIBSPDM_RECORD_TRANSCRIPT_DATA_SUPPORT=1 \
    -DLIBSPDM_AEAD_SM4_128_GCM_SUPPORT=0 \
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

INCLUDES="-I${ARTIFACT}/include \
    -I${ARTIFACT}/unit_test/include \
    -I${ARTIFACT}/os_stub/spdm_device_secret_lib_sample \
    -I${ARTIFACT}/unit_test/spdm_unit_test_common \
    -I${ARTIFACT}/os_stub \
    -I${HARNESS_SRC}"

LIBS="-Wl,--start-group \
    ${LIB_DIR}/libmemlib.a \
    ${LIB_DIR}/libdebuglib.a \
    ${LIB_DIR}/libspdm_responder_lib.a \
    ${LIB_DIR}/libspdm_requester_lib.a \
    ${LIB_DIR}/libspdm_common_lib.a \
    ${LIB_DIR}/librnglib.a \
    ${LIB_DIR}/libcryptlib_mbedtls.a \
    ${LIB_DIR}/libmalloclib.a \
    ${LIB_DIR}/libspdm_crypt_lib.a \
    ${LIB_DIR}/libspdm_crypt_ext_lib.a \
    ${LIB_DIR}/libspdm_secured_message_lib.a \
    ${LIB_DIR}/libspdm_device_secret_lib_sample.a \
    ${LIB_DIR}/libspdm_transport_test_lib.a \
    ${LIB_DIR}/libplatform_lib.a \
    -lpthread \
    ${LIB_DIR}/libmbedx509.a \
    ${LIB_DIR}/libmbedcrypto.a \
    -Wl,--end-group"

SUPPORT_SRCS="${HARNESS_SRC}/tla_trace.c ${HARNESS_SRC}/support.c"

mkdir -p "${BIN_DIR}"

build_test() {
    local name="$1"
    local src="${SCRIPT_DIR}/${name}.c"
    local out="${BIN_DIR}/${name}"
    echo "  Building ${name}..."
    # shellcheck disable=SC2086
    gcc ${CFLAGS} ${INCLUDES} "$src" ${SUPPORT_SRCS} ${LIBS} -o "$out"
    echo "  -> ${out}"
}

build_test test_bug1_l1l2_transcript_divergence
build_test test_bug2_nosig_oob_read
build_test test_bug3_resync_sessions_stranded
build_test test_bug4_slot_id_uninit

echo ""
echo "=== Build complete. Run from ${BIN_DIR}/ (needs ecp256/ cert files): ==="
echo "  cd ${BIN_DIR} && timeout 30s ./test_bug1_l1l2_transcript_divergence"
echo "  cd ${BIN_DIR} && timeout 30s ./test_bug2_nosig_oob_read"
echo "  cd ${BIN_DIR} && timeout 30s ./test_bug3_resync_sessions_stranded"
echo "  cd ${BIN_DIR} && timeout 30s ./test_bug4_slot_id_uninit"
