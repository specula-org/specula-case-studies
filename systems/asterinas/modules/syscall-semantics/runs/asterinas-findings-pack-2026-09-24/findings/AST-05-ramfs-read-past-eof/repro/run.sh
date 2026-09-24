#!/bin/sh
# Minimal userspace reproduction for RF-05.
# Build and run INSIDE an Asterinas guest (any user, public syscalls only):
#   cc -O2 -o /tmp/mc3 repro.c && /tmp/mc3 /mc3
# On a Linux host the same binary acts as the control and prints the
# Linux-correct values that Asterinas deviates from.
set -eu
cc -Wall -O2 -o /tmp/mc3 "$(dirname "$0")/repro.c"
/tmp/mc3 /mc3
