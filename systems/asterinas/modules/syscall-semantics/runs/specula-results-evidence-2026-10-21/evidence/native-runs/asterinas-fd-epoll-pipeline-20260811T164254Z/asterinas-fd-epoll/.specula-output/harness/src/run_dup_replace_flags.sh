#!/bin/sh

# SPDX-License-Identifier: MPL-2.0

set -eu
/test/io/specula/specula_fd_trace dup_replace_flags
echo "SPECULA_SCENARIO_PASS dup_replace_flags"
