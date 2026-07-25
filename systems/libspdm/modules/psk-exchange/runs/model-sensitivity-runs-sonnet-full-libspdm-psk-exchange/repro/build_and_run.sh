#!/bin/bash
# Build and run both reproduction tests for libspdm PSK exchange bugs.
set -e

REPRO_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT="$REPRO_DIR/../artifact/libspdm"
BUILD="$REPRO_DIR/../artifact/build"
LIB="$BUILD/lib"

CFLAGS="-O0 -std=c99 -fshort-wchar -fno-strict-aliasing -Wall -Wno-array-bounds \
  -ffunction-sections -fdata-sections -fno-common -Wno-address -fno-asynchronous-unwind-tables \
  -Wno-maybe-uninitialized -Wno-uninitialized -Wno-builtin-declaration-mismatch \
  -Wno-nonnull-compare -Wcast-qual -mno-red-zone -maccumulate-outgoing-args -g -m64 \
  -DUSING_LTO"

INCLUDES="-I$ARTIFACT/include \
  -I$ARTIFACT/unit_test/include \
  -I$ARTIFACT/os_stub/spdm_device_secret_lib_sample \
  -I$ARTIFACT/unit_test/spdm_unit_test_common \
  -I$ARTIFACT/unit_test/cmockalib/cmocka/include \
  -I$ARTIFACT/unit_test/cmockalib/cmocka/include/cmockery \
  -I$ARTIFACT/os_stub"

SUPPORT="$ARTIFACT/unit_test/spdm_unit_test_common/algo.c \
         $ARTIFACT/unit_test/spdm_unit_test_common/support.c"

LIBS="-Wl,--start-group \
  $LIB/libmemlib.a \
  $LIB/libdebuglib.a \
  $LIB/libspdm_responder_lib.a \
  $LIB/libspdm_requester_lib.a \
  $LIB/libspdm_common_lib.a \
  $LIB/librnglib.a \
  $LIB/libcryptlib_mbedtls.a \
  $LIB/libmalloclib.a \
  $LIB/libspdm_crypt_lib.a \
  $LIB/libspdm_crypt_ext_lib.a \
  $LIB/libspdm_secured_message_lib.a \
  $LIB/libspdm_device_secret_lib_sample.a \
  $LIB/libspdm_transport_test_lib.a \
  $LIB/libplatform_lib.a \
  $LIB/libmbedx509.a \
  $LIB/libmbedcrypto.a \
  -Wl,--end-group"

cd "$REPRO_DIR"

echo "=== Building test_bug1 ==="
gcc $CFLAGS $INCLUDES \
    test_bug1_zero_secured_message_version.c $SUPPORT \
    -o test_bug1 -no-pie $LIBS

echo "=== Building test_bug2 ==="
gcc $CFLAGS $INCLUDES \
    test_bug2_triple_callback_mismatch.c $SUPPORT \
    -o test_bug2 -no-pie -Wl,--allow-multiple-definition $LIBS

echo ""
echo "=== Running test_bug1 (MC-BUG-1) ==="
timeout 30s ./test_bug1; BUG1_RC=$?
echo "(exit code: $BUG1_RC)"

echo ""
echo "=== Running test_bug2 (MC-BUG-2) ==="
timeout 30s ./test_bug2; BUG2_RC=$?
echo "(exit code: $BUG2_RC)"

echo ""
echo "=== Summary ==="
echo "MC-BUG-1: $( [ $BUG1_RC -eq 0 ] && echo REPRODUCED || echo FAILED/REJECTED )"
echo "MC-BUG-2: $( [ $BUG2_RC -eq 0 ] && echo REPRODUCED || echo FAILED )"
