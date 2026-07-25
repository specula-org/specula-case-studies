#!/usr/bin/env bash
# apply.sh — Apply instrumentation to sonic-iccpd artifact
# Run from .specula-output/ directory
set -euo pipefail

ARTIFACT="$(cd "$(dirname "$0")/../artifact/sonic-buildimage/src/iccpd" && pwd)"
HARNESS_SRC="$(cd "$(dirname "$0")/src" && pwd)"
SRC="$ARTIFACT/src"
INC="$ARTIFACT/include"

echo "=== Applying instrumentation to $ARTIFACT ==="

# Step 1: Clean any previous instrumentation
cd "$ARTIFACT"
git checkout -- . 2>/dev/null || true

# Step 2: Copy trace module files
cp "$HARNESS_SRC/tla_trace.h" "$SRC/"
cp "$HARNESS_SRC/tla_trace.c" "$SRC/"
cp "$HARNESS_SRC/test_harness.c" "$SRC/"

echo "Copied trace module and test harness"

# Step 3: Instrument source files using Python with pattern-based patching
python3 - "$SRC" <<'PYEOF'
import sys, os, re

src_dir = sys.argv[1]

def add_include(filename, include_line):
    """Add an include directive after the last existing include."""
    filepath = os.path.join(src_dir, filename)
    with open(filepath, 'r') as f:
        lines = f.readlines()
    last_inc = 0
    for i, line in enumerate(lines):
        if line.strip().startswith('#include'):
            last_inc = i
    lines.insert(last_inc + 1, include_line + '\n')
    with open(filepath, 'w') as f:
        f.writelines(lines)

def insert_after_pattern(filename, pattern, insert_text, occurrence=1):
    """Insert text after the Nth occurrence of a pattern (substring match)."""
    filepath = os.path.join(src_dir, filename)
    with open(filepath, 'r') as f:
        lines = f.readlines()
    count = 0
    for i, line in enumerate(lines):
        if pattern in line:
            count += 1
            if count == occurrence:
                # Detect indentation
                indent = len(line) - len(line.lstrip())
                lines.insert(i + 1, ' ' * indent + insert_text + '\n')
                break
    with open(filepath, 'w') as f:
        f.writelines(lines)
    if count < occurrence:
        print(f"  WARNING: pattern '{pattern.strip()}' occurrence {occurrence} not found in {filename}")
    else:
        print(f"  Patched {filename}: {insert_text.strip()[:60]}")

def insert_before_pattern(filename, pattern, insert_text, occurrence=1):
    """Insert text before the Nth occurrence of a pattern."""
    filepath = os.path.join(src_dir, filename)
    with open(filepath, 'r') as f:
        lines = f.readlines()
    count = 0
    for i, line in enumerate(lines):
        if pattern in line:
            count += 1
            if count == occurrence:
                indent = len(line) - len(line.lstrip())
                lines.insert(i, ' ' * indent + insert_text + '\n')
                break
    with open(filepath, 'w') as f:
        f.writelines(lines)
    if count < occurrence:
        print(f"  WARNING: pattern '{pattern.strip()}' occurrence {occurrence} not found in {filename}")
    else:
        print(f"  Patched {filename}: {insert_text.strip()[:60]}")

def replace_line_containing(filename, pattern, old_text, new_text, occurrence=1):
    """Replace specific text within a line containing a pattern."""
    filepath = os.path.join(src_dir, filename)
    with open(filepath, 'r') as f:
        content = f.read()
    count = 0
    pos = 0
    while True:
        idx = content.find(old_text, pos)
        if idx == -1:
            break
        count += 1
        if count == occurrence:
            content = content[:idx] + new_text + content[idx + len(old_text):]
            break
        pos = idx + 1
    with open(filepath, 'w') as f:
        f.write(content)

# ================================================================
# Instrument mlacp_fsm.c
# ================================================================
add_include('mlacp_fsm.c', '#include "tla_trace.h"')

# 2.20 SendHeartbeat: after time(&csm->heartbeat_send_time); in mlacp_sync_send_heartbeat
insert_after_pattern('mlacp_fsm.c',
    'time(&csm->heartbeat_send_time);',
    'tla_trace_emit("SendHeartbeat", csm);')

# 2.3 MlacpInitToStage1: after MLACP(csm).current_state = MLACP_STATE_STAGE1;
insert_after_pattern('mlacp_fsm.c',
    'MLACP(csm).current_state = MLACP_STATE_STAGE1;',
    'tla_trace_emit("MlacpInitToStage1", csm);')

# 2.10 MlacpReceiveNAK (SysConfig): after MLACP(csm).node_id--;
insert_after_pattern('mlacp_fsm.c',
    'MLACP(csm).node_id--;',
    'tla_trace_emit_nak("MlacpReceiveNAK", csm, "SysConfig");')

# 2.10 MlacpReceiveNAK (Other): after MLACP(csm).need_to_sync = 1;
# There are multiple occurrences; we want the one in mlacp_sync_recv_nak_handler
insert_after_pattern('mlacp_fsm.c',
    'MLACP(csm).need_to_sync = 1;',
    'tla_trace_emit_nak("MlacpReceiveNAK", csm, "Other");')

# 2.5 MlacpStageSendAllInfo: after MLACP(csm).current_state++; in mlacp_sync_send_all_info_handler
# This line has a break; right after it. We need to insert BEFORE the break.
# The pattern: "MLACP(csm).current_state++;" followed by "break;"
# Use the break after current_state++ in the else block (first occurrence of break after current_state++)
# Strategy: replace "current_state++;\n            break;" with "current_state++;\n            tla_trace...\n            break;"
filepath = os.path.join(src_dir, 'mlacp_fsm.c')
with open(filepath, 'r') as f:
    content = f.read()
# Find current_state++ followed by break in mlacp_sync_send_all_info_handler
old = 'MLACP(csm).current_state++;\n            break;'
new = 'MLACP(csm).current_state++;\n            tla_trace_emit("MlacpStageSendAllInfo", csm);\n            break;'
if old in content:
    content = content.replace(old, new, 1)
    print('  Patched mlacp_fsm.c: MlacpStageSendAllInfo (before break)')
else:
    print('  WARNING: MlacpStageSendAllInfo pattern not found')
with open(filepath, 'w') as f:
    f.write(content)

# 2.4 MlacpSendSyncRequest: after MLACP(csm).wait_for_sync_data = 1; in stage_sync_request_handler
# This is the first occurrence in stage_sync_request_handler
insert_after_pattern('mlacp_fsm.c',
    'MLACP(csm).wait_for_sync_data = 1;',
    'tla_trace_emit("MlacpSendSyncRequest", csm);',
    occurrence=2)  # 2nd occurrence: 1st is in stage_sync_send_handler

# 2.6 MlacpReceiveSyncDone: after MLACP(csm).current_state++; in stage_sync_request_handler
# This is the 2nd occurrence of current_state++ (1st was in mlacp_sync_send_all_info_handler)
insert_after_pattern('mlacp_fsm.c',
    'MLACP(csm).current_state++;',
    'tla_trace_emit("MlacpReceiveSyncDone", csm);',
    occurrence=2)

# 2.7 MlacpSendSyncRequestFromExchange: after iccp_csm_send for sync request in exchange_handler
# Direct pattern replacement: need_to_sync block with prepare + send
filepath = os.path.join(src_dir, 'mlacp_fsm.c')
with open(filepath, 'r') as f:
    content = f.read()
old_block = 'MLACP(csm).need_to_sync = 0;\n        memset(g_csm_buf, 0, CSM_BUFFER_SIZE);\n        len = mlacp_prepare_for_sync_request_tlv(csm, g_csm_buf, CSM_BUFFER_SIZE);\n        iccp_csm_send(csm, g_csm_buf, len);'
new_block = 'MLACP(csm).need_to_sync = 0;\n        memset(g_csm_buf, 0, CSM_BUFFER_SIZE);\n        len = mlacp_prepare_for_sync_request_tlv(csm, g_csm_buf, CSM_BUFFER_SIZE);\n        iccp_csm_send(csm, g_csm_buf, len);\n        tla_trace_emit("MlacpSendSyncRequestFromExchange", csm);'
if old_block in content:
    content = content.replace(old_block, new_block, 1)
    print('  Patched mlacp_fsm.c: MlacpSendSyncRequestFromExchange')
else:
    print('  WARNING: MlacpSendSyncRequestFromExchange pattern not found')
with open(filepath, 'w') as f:
    f.write(content)

# ================================================================
# Instrument mlacp_sync_update.c
# ================================================================
add_include('mlacp_sync_update.c', '#include "tla_trace.h"')

# 2.11 ReceiveSysConfig: after the node_id collision block, emit before return
# Use unique pattern: the function has "MLACP(csm).node_id++;" — emit after it
insert_after_pattern('mlacp_sync_update.c',
    'MLACP(csm).node_id++;',
    'tla_trace_emit_sysconfig("ReceiveSysConfig", csm, sysconf->node_id);')

# 2.21 ReceiveHeartbeat: after time(&csm->heartbeat_update_time);
insert_after_pattern('mlacp_sync_update.c',
    'time(&csm->heartbeat_update_time);',
    'tla_trace_emit("ReceiveHeartbeat", csm);')

# 2.24 PeerWarmBoot: after time(&csm->peer_warm_reboot_time);
insert_after_pattern('mlacp_sync_update.c',
    'time(&csm->peer_warm_reboot_time);',
    'tla_trace_emit("PeerWarmBoot", csm);')

# ================================================================
# Instrument scheduler.c
# ================================================================
add_include('scheduler.c', '#include "tla_trace.h"')

# 2.22 HeartbeatTimeout: before scheduler_session_disconnect_handler(csm); in heartbeat_check
insert_before_pattern('scheduler.c',
    'scheduler_session_disconnect_handler(csm);',
    'tla_trace_emit("HeartbeatTimeout", csm);')

# 2.23 SessionDisconnect: after iccp_csm_status_reset(csm, 0);
insert_after_pattern('scheduler.c',
    'iccp_csm_status_reset(csm, 0);',
    'tla_trace_emit("SessionDisconnect", csm);')

# ================================================================
# Instrument iccp_csm.c — override iccp_csm_send for test mode
# ================================================================
add_include('iccp_csm.c', '#include "tla_trace.h"')

# Replace the write() call in iccp_csm_send with a test-mode routing call
filepath = os.path.join(src_dir, 'iccp_csm.c')
with open(filepath, 'r') as f:
    content = f.read()

# Add the extern declaration for tla_route_message after the include
content = content.replace(
    '#include "tla_trace.h"',
    '#include "tla_trace.h"\n'
    '#ifdef TLA_TRACE_TEST\n'
    'extern void tla_route_message(struct CSM *src, char *buf, int len);\n'
    '#endif'
)

# Replace write() call in iccp_csm_send with conditional
content = content.replace(
    '    rc = write(csm->sock_fd, buf, msg_len);',
    '#ifdef TLA_TRACE_TEST\n'
    '    tla_route_message(csm, buf, msg_len);\n'
    '    rc = msg_len;\n'
    '#else\n'
    '    rc = write(csm->sock_fd, buf, msg_len);\n'
    '#endif'
)

with open(filepath, 'w') as f:
    f.write(content)
print("  Patched iccp_csm.c: write() override for test mode")

print("\n=== Instrumentation complete ===")
PYEOF

# Step 4: Create the test Makefile
cat > "$SRC/Makefile.test" <<'MAKEFILE'
# Makefile.test — Build sonic-iccpd trace test binary
CC = gcc
CFLAGS = -DHAVE_CONFIG_H -I. -I.. -I../include -I/usr/include/libnl3 \
         -DTLA_TRACE_TEST -g -O2 -Wno-unused-result -Wno-format-truncation \
         -D_FORTIFY_SOURCE=2
LDFLAGS = -lnl-genl-3 -lnl-route-3 -lnl-3 -lpthread

# All source files except iccp_main.c (replaced by test_harness.c)
SRCS = test_harness.c tla_trace.c \
       app_csm.c iccp_csm.c mlacp_fsm.c mlacp_sync_update.c \
       mlacp_sync_prepare.c mlacp_link_handler.c \
       scheduler.c system.c port.c logger.c openbsd_tree.c \
       iccp_consistency_check.c iccp_ifm.c cmd_option.c \
       iccp_cli.c iccp_cmd.c iccp_cmd_show.c iccp_netlink.c

# Note: iccp_main.c excluded — replaced by test_harness.c
# Note: iccp_netlink.c included — links against real libnl3
#       Network operations will fail gracefully at runtime (no kernel)

OBJS = $(SRCS:.c=.o)
TARGET = iccpd_test

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(TARGET)

.PHONY: all clean
MAKEFILE

echo "Created Makefile.test"
echo ""
echo "Apply complete. Build with: cd $SRC && make -f Makefile.test"
