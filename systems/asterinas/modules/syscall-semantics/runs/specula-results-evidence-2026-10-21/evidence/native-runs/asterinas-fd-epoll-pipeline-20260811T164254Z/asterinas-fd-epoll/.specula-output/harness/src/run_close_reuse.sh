#!/bin/sh

# SPDX-License-Identifier: MPL-2.0

set -eu
/test/io/specula/specula_fd_trace close_reuse
echo "SPECULA_SCENARIO_PASS close_reuse"
