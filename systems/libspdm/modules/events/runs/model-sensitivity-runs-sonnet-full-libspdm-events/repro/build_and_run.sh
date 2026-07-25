#!/bin/bash
# Build and run all three BUG reproduction tests.
set -e

LIBSPDM_DIR="$(cd "$(dirname "$0")/../artifact/libspdm" && pwd)"
BUILD_DIR="$(cd "$(dirname "$0")/../build" && pwd)"
REPRO_DIR="$(cd "$(dirname "$0")" && pwd)"

INCLUDES=(
    "-I${LIBSPDM_DIR}/include"
    "-I${LIBSPDM_DIR}/unit_test/spdm_unit_test_common"
    "-I${LIBSPDM_DIR}/unit_test/include"
    "-I${LIBSPDM_DIR}/unit_test/test_spdm_responder"
    "-I${LIBSPDM_DIR}/unit_test/test_tla_trace"
    "-I${LIBSPDM_DIR}/unit_test/cmockalib/cmocka/include"
    "-I${LIBSPDM_DIR}/unit_test/cmockalib/cmocka/include/cmockery"
    "-I${LIBSPDM_DIR}/os_stub/spdm_device_secret_lib_sample"
    "-I${LIBSPDM_DIR}/os_stub"
)

DEFINES=(
    "-DTLA_TRACE_ENABLED"
    "-DLIBSPDM_AEAD_SM4_128_GCM_SUPPORT=0"
    "-DLIBSPDM_EDDSA_ED25519_SUPPORT=0"
    "-DLIBSPDM_EDDSA_ED448_SUPPORT=0"
    "-DLIBSPDM_ML_DSA_44_SUPPORT=0"
    "-DLIBSPDM_ML_DSA_65_SUPPORT=0"
    "-DLIBSPDM_ML_DSA_87_SUPPORT=0"
    "-DLIBSPDM_ML_KEM_1024_SUPPORT=0"
    "-DLIBSPDM_ML_KEM_512_SUPPORT=0"
    "-DLIBSPDM_ML_KEM_768_SUPPORT=0"
    "-DLIBSPDM_SLH_DSA_SHA2_128F_SUPPORT=0"
    "-DLIBSPDM_SLH_DSA_SHA2_128S_SUPPORT=0"
    "-DLIBSPDM_SLH_DSA_SHA2_192F_SUPPORT=0"
    "-DLIBSPDM_SLH_DSA_SHA2_192S_SUPPORT=0"
    "-DLIBSPDM_SLH_DSA_SHA2_256F_SUPPORT=0"
    "-DLIBSPDM_SLH_DSA_SHA2_256S_SUPPORT=0"
    "-DLIBSPDM_SLH_DSA_SHAKE_128F_SUPPORT=0"
    "-DLIBSPDM_SLH_DSA_SHAKE_128S_SUPPORT=0"
    "-DLIBSPDM_SLH_DSA_SHAKE_192F_SUPPORT=0"
    "-DLIBSPDM_SLH_DSA_SHAKE_192S_SUPPORT=0"
    "-DLIBSPDM_SLH_DSA_SHAKE_256F_SUPPORT=0"
    "-DLIBSPDM_SLH_DSA_SHAKE_256S_SUPPORT=0"
    "-DLIBSPDM_SM2_DSA_P256_SUPPORT=0"
    "-DLIBSPDM_SM2_KEY_EXCHANGE_P256_SUPPORT=0"
    "-DLIBSPDM_SM3_256_SUPPORT=0"
)

LIBS=(
    "${BUILD_DIR}/lib/libmemlib.a"
    "${BUILD_DIR}/lib/libdebuglib.a"
    "${BUILD_DIR}/lib/libspdm_requester_lib.a"
    "${BUILD_DIR}/lib/libspdm_responder_lib.a"
    "${BUILD_DIR}/lib/libspdm_common_lib.a"
    "${BUILD_DIR}/lib/librnglib.a"
    "${BUILD_DIR}/lib/libcryptlib_mbedtls.a"
    "${BUILD_DIR}/lib/libmalloclib.a"
    "${BUILD_DIR}/lib/libspdm_crypt_lib.a"
    "${BUILD_DIR}/lib/libspdm_crypt_ext_lib.a"
    "${BUILD_DIR}/lib/libspdm_secured_message_lib.a"
    "${BUILD_DIR}/lib/libspdm_device_secret_lib_sample.a"
    "${BUILD_DIR}/lib/libspdm_transport_test_lib.a"
    "${BUILD_DIR}/lib/libplatform_lib.a"
    "${BUILD_DIR}/lib/libmbedx509.a"
    "${BUILD_DIR}/lib/libmbedcrypto.a"
)

# Extra source files needed to supply tla_emit_*, m_libspdm_use_*, and OS stubs
EXTRA_SRCS=(
    "${LIBSPDM_DIR}/unit_test/test_spdm_responder/tla_trace.c"
    "${LIBSPDM_DIR}/unit_test/spdm_unit_test_common/support.c"
    "${LIBSPDM_DIR}/unit_test/spdm_unit_test_common/algo.c"
)

echo "Building repro tests..."
echo

build_test() {
    local src="$1"
    local bin="$2"
    gcc -g -O0 \
        "${INCLUDES[@]}" \
        "${DEFINES[@]}" \
        "$src" \
        "${EXTRA_SRCS[@]}" \
        -Wl,--start-group \
        "${LIBS[@]}" \
        -Wl,--end-group \
        -lm -lpthread \
        -o "$bin" 2>&1
}

RESULTS=()

for BUG in 1 2 3; do
    case $BUG in
        1) SRC="${REPRO_DIR}/test_bug1_response_state_check_order.c" ;;
        2) SRC="${REPRO_DIR}/test_bug2_subscribe_none_overrides_event_all.c" ;;
        3) SRC="${REPRO_DIR}/test_bug3_encap_no_subscription_check.c" ;;
    esac
    BIN="${REPRO_DIR}/test_bug${BUG}"

    echo "--- Building BUG-${BUG} ---"
    if build_test "$SRC" "$BIN"; then
        echo "Build OK"
    else
        echo "Build FAILED"
        RESULTS+=("BUG-${BUG}: BUILD FAILED")
        continue
    fi

    echo "--- Running BUG-${BUG} ---"
    timeout 30 "$BIN"
    RC=$?
    case $RC in
        0) RESULTS+=("BUG-${BUG}: REPRODUCED (exit 0)");;
        1) RESULTS+=("BUG-${BUG}: NOT reproduced / unexpected (exit 1)");;
        2) RESULTS+=("BUG-${BUG}: SETUP ERROR (exit 2)");;
        *) RESULTS+=("BUG-${BUG}: TIMEOUT or crash (exit ${RC})");;
    esac
    echo
done

echo "========================================"
echo "SUMMARY"
echo "========================================"
for r in "${RESULTS[@]}"; do echo "  $r"; done
