#!/bin/sh
# AST-09 userspace repro: readv/writev on blocking pipe must restart under SA_RESTART.
# On Linux: all 5 checks PASS (readv/writev restart, never return EINTR).
# On Asterinas: checks 2/4 FAIL (readv/writev return EINTR despite SA_RESTART).
set -eu
cc -Wall -O2 -o /tmp/ast09 "$(dirname "$0")/repro.c"
/tmp/ast09
