LIBSPDM := $(realpath ../artifact/libspdm)
BUILD   := $(LIBSPDM)/build
LIBDIR  := $(BUILD)/lib

CC := gcc
CFLAGS := -std=c99 -fshort-wchar -fno-strict-aliasing -Wall \
          -fno-common -fpie \
          -DLIBSPDM_ENABLE_CAPABILITY_CHUNK_CAP=1 \
          -DLIBSPDM_ENABLE_CAPABILITY_CERT_CAP=1 \
          -DLIBSPDM_ENABLE_CAPABILITY_MEAS_CAP=1 \
          -DLIBSPDM_ENABLE_CAPABILITY_KEY_EX_CAP=1 \
          -DLIBSPDM_ENABLE_CAPABILITY_PSK_CAP=1 \
          -DLIBSPDM_ENABLE_CAPABILITY_MUT_AUTH_CAP=1 \
          -DLIBSPDM_ENABLE_CAPABILITY_ENCAP_CAP=1 \
          -DLIBSPDM_SEND_GET_CERTIFICATE_SUPPORT=1 \
          -DLIBSPDM_SEND_CHALLENGE_SUPPORT=1 \
          -DLIBSPDM_RESPOND_IF_READY_SUPPORT=1 \
          -DLIBSPDM_ENABLE_VENDOR_DEFINED_MESSAGES=1 \
          -DLIBSPDM_MAX_SPDM_MSG_SIZE=0x1200 \
          -DUSING_LTO \
          -Wno-implicit-function-declaration \
          -Wno-maybe-uninitialized \
          -Wno-cast-qual \
          -Wno-array-bounds

INCLUDES := \
  -I$(LIBSPDM)/include \
  -I$(LIBSPDM)/include/hal \
  -I$(LIBSPDM)/unit_test/include \
  -I$(LIBSPDM)/unit_test/spdm_unit_test_common \
  -I$(LIBSPDM)/unit_test/cmockalib/cmocka/include \
  -I$(LIBSPDM)/unit_test/cmockalib/cmocka/include/cmockery

LIBS_SPDM := \
  $(LIBDIR)/libspdm_responder_lib.a \
  $(LIBDIR)/libspdm_requester_lib.a \
  $(LIBDIR)/libspdm_common_lib.a \
  $(LIBDIR)/libspdm_secured_message_lib.a \
  $(LIBDIR)/libspdm_crypt_lib.a \
  $(LIBDIR)/libcryptlib_mbedtls.a \
  $(LIBDIR)/libspdm_crypt_ext_lib.a \
  $(LIBDIR)/libspdm_device_secret_lib_sample.a \
  $(LIBDIR)/libspdm_transport_test_lib.a \
  $(LIBDIR)/libdebuglib.a \
  $(LIBDIR)/libmemlib.a \
  $(LIBDIR)/libmalloclib.a \
  $(LIBDIR)/librnglib.a \
  $(LIBDIR)/libplatform_lib.a \
  $(LIBDIR)/libmbedx509.a \
  $(LIBDIR)/libmbedcrypto.a

LIBS_STD := -lm -lpthread -ldl

all: test_bug1 test_bug2 test_bug3 test_bug4 test_bug5

test_bug1: test_bug1_last_chunk_omitted.c
	$(CC) -std=c99 -Wall -Wno-unused-function -o $@ test_bug1_last_chunk_omitted.c

test_bug2: test_bug2_seq_no_corruption.c stubs.c
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ \
	  test_bug2_seq_no_corruption.c stubs.c \
	  -Wl,--start-group $(LIBS_SPDM) -Wl,--end-group $(LIBS_STD)

test_bug3: test_bug3_buffer_overflow_success.c
	$(CC) -std=c99 -Wall -o $@ test_bug3_buffer_overflow_success.c

test_bug4: test_bug4_source_oob_copy.c
	$(CC) -std=c99 -Wall -Wno-unused-function -Wno-unused-variable -o $@ test_bug4_source_oob_copy.c

test_bug5: test_bug5_mutual_exclusion.c stubs.c
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ \
	  test_bug5_mutual_exclusion.c stubs.c \
	  -Wl,--start-group $(LIBS_SPDM) -Wl,--end-group $(LIBS_STD)

run: all
	@echo "=== Bug 3 ==="
	./test_bug3; echo "Exit: $$?"
	@echo ""
	@echo "=== Bug 2 ==="
	./test_bug2; echo "Exit: $$?"
	@echo ""
	@echo "=== Bug 5 ==="
	./test_bug5; echo "Exit: $$?"

.PHONY: all run
