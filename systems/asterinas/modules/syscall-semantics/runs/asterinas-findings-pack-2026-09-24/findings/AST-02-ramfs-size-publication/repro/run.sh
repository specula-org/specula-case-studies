#!/bin/sh
# Minimal userspace reproduction for AST-02.
# Build and run inside an Asterinas guest with write access to the target:
#   cc -O2 -o /tmp/mc4 repro.c && /tmp/mc4 /
# Compile the same source separately on a Linux host to obtain the control
# values that Asterinas deviates from.
set -eu
cc -Wall -O2 -o /tmp/mc4 "$(dirname "$0")/repro.c"
/tmp/mc4 /
