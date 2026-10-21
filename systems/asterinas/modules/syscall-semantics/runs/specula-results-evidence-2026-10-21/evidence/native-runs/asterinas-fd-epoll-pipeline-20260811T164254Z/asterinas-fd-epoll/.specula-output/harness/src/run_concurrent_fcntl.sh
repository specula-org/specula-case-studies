#!/bin/sh

# SPDX-License-Identifier: MPL-2.0

set -eu
/test/io/specula/specula_fd_trace concurrent_fcntl
echo "SPECULA_SCENARIO_PASS concurrent_fcntl"
