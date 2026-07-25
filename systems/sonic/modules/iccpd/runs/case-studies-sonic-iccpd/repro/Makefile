# Makefile — Build sonic-iccpd bug reproduction test binary
# Uses already-compiled .o files from the iccpd build.
#
# ASAN=1: link against .asan.o files (built with -fsanitize=address) for
#         heap-buffer-overflow detection across all iccpd code paths.
# Otherwise: link against the standard .o files.
ICCPD_SRC = ../artifact/sonic-buildimage/src/iccpd/src
ICCPD_INC = ../artifact/sonic-buildimage/src/iccpd/include

CC = gcc
ifeq ($(ASAN),1)
  OSUF = .asan.o
  CFLAGS = -DHAVE_CONFIG_H -I$(ICCPD_SRC) -I$(ICCPD_INC) \
           -I/usr/include/libnl3 \
           -DTLA_TRACE_TEST -g -O0 -Wno-unused-result -Wno-format-truncation \
           -fsanitize=address -fno-omit-frame-pointer
  # ASAN-instrumented logger.o calls plain syslog() (no -D_FORTIFY_SOURCE), so
  # only --wrap=syslog is needed (no __syslog_chk in this build).
  LDFLAGS = -lnl-genl-3 -lnl-route-3 -lnl-3 -lpthread \
            -fsanitize=address \
            -Wl,--wrap=syslog -Wl,--wrap=sleep
else
  OSUF = .o
  CFLAGS = -DHAVE_CONFIG_H -I$(ICCPD_SRC) -I$(ICCPD_INC) \
           -I/usr/include/libnl3 \
           -DTLA_TRACE_TEST -g -O2 -Wno-unused-result -Wno-format-truncation \
           -D_FORTIFY_SOURCE=2
  LDFLAGS = -lnl-genl-3 -lnl-route-3 -lnl-3 -lpthread \
            -Wl,--wrap=syslog -Wl,--wrap=__syslog_chk -Wl,--wrap=sleep
endif

# iccp_ifm.exposed.o = same code, but with select 'static' symbols promoted to
# external so the test driver can call them. Used to reach
# do_ndisc_learn_from_kernel for Bug T1 real reproduction.
ICCP_IFM_EXPOSED = $(ICCPD_SRC)/iccp_ifm.exposed$(OSUF)

$(ICCP_IFM_EXPOSED): $(ICCPD_SRC)/iccp_ifm$(OSUF)
	objcopy --globalize-symbol=do_ndisc_learn_from_kernel $< $@

ICCPD_OBJS = $(ICCPD_SRC)/tla_trace$(OSUF) \
             $(ICCPD_SRC)/app_csm$(OSUF) $(ICCPD_SRC)/iccp_csm$(OSUF) \
             $(ICCPD_SRC)/mlacp_fsm$(OSUF) $(ICCPD_SRC)/mlacp_sync_update$(OSUF) \
             $(ICCPD_SRC)/mlacp_sync_prepare$(OSUF) $(ICCPD_SRC)/mlacp_link_handler$(OSUF) \
             $(ICCPD_SRC)/scheduler$(OSUF) $(ICCPD_SRC)/system$(OSUF) \
             $(ICCPD_SRC)/port$(OSUF) $(ICCPD_SRC)/logger$(OSUF) \
             $(ICCPD_SRC)/openbsd_tree$(OSUF) \
             $(ICCPD_SRC)/iccp_consistency_check$(OSUF) \
             $(ICCP_IFM_EXPOSED) $(ICCPD_SRC)/cmd_option$(OSUF) \
             $(ICCPD_SRC)/iccp_cli$(OSUF) $(ICCPD_SRC)/iccp_cmd$(OSUF) \
             $(ICCPD_SRC)/iccp_cmd_show$(OSUF) $(ICCPD_SRC)/iccp_netlink$(OSUF)

TEST_OBJ = test_repro.o
TARGET = test_repro

all: $(TARGET)

$(TARGET): $(TEST_OBJ)
	$(CC) $(CFLAGS) -o $@ $< $(ICCPD_OBJS) $(LDFLAGS)

$(TEST_OBJ): test_repro.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(TEST_OBJ) $(TARGET)

.PHONY: all clean
