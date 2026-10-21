#!/bin/sh
set -eu
/test/io/specula/specula_io_trace ramfs_zero_append
echo "SPECULA_SCENARIO_PASS ramfs_zero_append"
