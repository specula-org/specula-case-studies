#!/usr/bin/env bash
# Compatibility alias for the normal registered, budgeted checking entrypoint.
# Historical convergence logs and labels remain intact.
set -euo pipefail
spec_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
round="${1:-1}"
[[ "$round" =~ ^[1-9][0-9]*$ ]] || { printf 'Round must be a positive integer.\n' >&2; exit 2; }
case "${2:-bfs}" in
    bfs) exec "$spec_dir/run-checks.sh" check MC.cfg ;;
    simulate) exec "$spec_dir/run-checks.sh" simulate MC.cfg ;;
    *) printf 'Mode must be bfs or simulate.\n' >&2; exit 2 ;;
esac
