#!/bin/sh
set -eu
/test/io/specula/specula_io_trace ramfs_faults
echo "SPECULA_SCENARIO_PASS ramfs_faults"
