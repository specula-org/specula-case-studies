#!/bin/sh
# Minimal userspace reproduction for AST-03.
# Build and run inside an Asterinas guest with write access to the target:
#   cc -O2 -pthread -o /tmp/mc5 repro.c && /tmp/mc5 /
# Compile the same source separately on a Linux host to obtain the control
# values that Asterinas deviates from.
set -eu
cc -Wall -O2 -pthread -o /tmp/mc5 "$(dirname "$0")/repro.c"
/tmp/mc5 /
