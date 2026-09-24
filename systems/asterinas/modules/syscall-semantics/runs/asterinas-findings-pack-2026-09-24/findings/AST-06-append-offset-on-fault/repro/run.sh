#!/bin/sh
# Minimal userspace reproduction for RF-06.
# Build and run INSIDE an Asterinas guest (any user, public syscalls only):
#   cc -O2 -o /tmp/mc7 repro.c && /tmp/mc7 /ext2
# On a Linux host the same binary acts as the control and prints the
# Linux-correct values that Asterinas deviates from.
set -eu
cc -Wall -O2 -o /tmp/mc7 "$(dirname "$0")/repro.c"
/tmp/mc7 /ext2
