CC      = gcc
HARNESS = $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
LIBSPDM = $(HARNESS)../artifact/libspdm

CFLAGS  = -g -O0 -std=c11 -D_POSIX_C_SOURCE=200809L \
          -DLIBSPDM_ENABLE_CAPABILITY_CHUNK_CAP=1 \
          -DLIBSPDM_RESPOND_IF_READY_SUPPORT=1 \
          -DLIBSPDM_DEBUG_ASSERT_ENABLE=0 \
          -DLIBSPDM_DEBUG_PRINT_ENABLE=0 \
          -I$(LIBSPDM)/include \
          -I$(LIBSPDM)/os_stub/include \
          -I$(HARNESS)src \
          -Wno-implicit-function-declaration \
          -Wno-unused-variable \
          -Wno-unused-but-set-variable

SRCS    = $(HARNESS)src/spdm_stubs.c \
          $(HARNESS)src/spdm_harness.c \
          $(LIBSPDM)/library/spdm_responder_lib/libspdm_rsp_chunk_send_ack.c \
          $(LIBSPDM)/library/spdm_responder_lib/libspdm_rsp_chunk_response.c \
          $(LIBSPDM)/library/spdm_requester_lib/libspdm_req_handle_error_response.c

TARGET  = $(HARNESS)spdm_harness

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CC) $(CFLAGS) -o $@ $(SRCS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
