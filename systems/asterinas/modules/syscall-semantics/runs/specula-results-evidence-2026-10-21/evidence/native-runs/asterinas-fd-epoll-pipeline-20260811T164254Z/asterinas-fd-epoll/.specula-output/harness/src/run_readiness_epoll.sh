#!/bin/sh

# SPDX-License-Identifier: MPL-2.0

set -eu
/test/io/specula/specula_fd_trace readiness_epoll
echo "SPECULA_SCENARIO_PASS readiness_epoll"
