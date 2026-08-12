#!/usr/bin/env bash
set -euo pipefail

# MC-2 reproduction against the repository's real finalize-warmboot.sh and
# service_mgmt.sh entry points.
#
# Escalation:
#   Level 0: native SONiC commands are probed first.
#   Level 1: timing-only native execution is considered next.
#   Level 2: because this host is not a SONiC image, an isolated command/DB
#            fixture injects the late registration state. The injected state is
#            reachable through this real public call sequence:
#
#   sudo spm install --enable <package>
#     -> PackageManager.install()
#     -> PackageManager.install_from_source()
#     -> ServiceCreator.create()
#     -> ServiceCreator.generate_service_reconciliation_file()
#     -> /etc/sonic/<service>_reconcile is written
#
# See sonic-utilities at buildimage's pinned submodule SHA b17c48270c15fc6d5c81a23d97e2946cd7059dcd:
#   sonic_package_manager/main.py:394-460
#   sonic_package_manager/manager.py:350-461
#   sonic_package_manager/service_creator/creator.py:163-195,518-532
#
# The injection is synchronized after the finalizer's one-time find(1), at the
# first subsequent CONFIG_DB scope query. No finalizer or consumer source is
# patched; dependency responses are ordinary successful SONiC responses.

readonly WORKTREE="/users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/confirmation/MC-2/worktree"
readonly FINALIZER="$WORKTREE/files/image_config/warmboot-finalizer/finalize-warmboot.sh"
readonly CONSUMER="$WORKTREE/files/scripts/service_mgmt.sh"

if [[ ! -x "$FINALIZER" || ! -r "$CONSUMER" ]]; then
    echo "HARNESS_ERROR: production entry points are unavailable"
    exit 2
fi

native_missing=()
for command_name in sonic-db-cli config spm; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        native_missing+=("$command_name")
    fi
done

if ((${#native_missing[@]})); then
    echo "LEVEL0: FAIL native SONiC runtime unavailable; missing=${native_missing[*]}"
    echo "LEVEL1: FAIL timing assistance alone cannot run absent SONiC public APIs"
else
    echo "LEVEL0: native commands exist (this harness still uses its isolated deterministic fixture)"
    echo "LEVEL1: native timing attempt not selected because deterministic Level 2 evidence follows"
fi

if ! command -v bwrap >/dev/null 2>&1 || ! sudo -n true; then
    echo "HARNESS_ERROR: bwrap and passwordless sudo are required for the isolated filesystem view"
    exit 2
fi

fixture_dir=$(mktemp -d)
cleanup() {
    if [[ -n "${finalizer_pid:-}" ]]; then
        kill "$finalizer_pid" >/dev/null 2>&1 || true
        wait "$finalizer_pid" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$fixture_dir"
}
trap cleanup EXIT

mkdir -p "$fixture_dir/etc-sonic" "$fixture_dir/state" "$fixture_dir/bin"
printf '%s\n' true > "$fixture_dir/state/global_warm_flag"
printf '%s\n' restoring > "$fixture_dir/state/latecomp_state"

cat > "$fixture_dir/bin/sonic-db-cli" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf 'sonic-db-cli %q ' "$@" >> "$STATE_ROOT/db_calls.log"
printf '\n' >> "$STATE_ROOT/db_calls.log"

if [[ "${1:-}" == "-n" ]]; then
    shift 2
fi

db=${1:-}
operation=${2:-}
key=${3:-}
field=${4:-}

if [[ "$db" == "PING" ]]; then
    echo PONG
    exit 0
fi

if [[ "$db" == "CONFIG_DB" && "${operation^^}" == "GET" && "$key" == "CONFIG_DB_INITIALIZED" ]]; then
    echo 1
    exit 0
fi

if [[ "$db" == "CONFIG_DB" && "${operation^^}" == "HGET" ]]; then
    if [[ "$key" == FEATURE\|* && ("$field" == "has_per_asic_scope" || "$field" == "has_global_scope") ]]; then
        if [[ ! -e "$STATE_ROOT/snapshot_observed" ]]; then
            : > "$STATE_ROOT/snapshot_observed"
            deadline=$((SECONDS + 5))
            until [[ -e "$STATE_ROOT/registration_injected" ]]; do
                if ((SECONDS >= deadline)); then
                    echo "fixture registration synchronization timed out" >&2
                    exit 70
                fi
                sleep 0.01
            done
        fi
        echo false
        exit 0
    fi

    if [[ "$key" == FEATURE\|late && "$field" == "state" ]]; then
        echo enabled
    else
        echo disabled
    fi
    exit 0
fi

if [[ "$db" == "STATE_DB" && "${operation,,}" == "hget" ]]; then
    case "$key:$field" in
        'WARM_RESTART_ENABLE_TABLE|system:enable')
            cat "$STATE_ROOT/global_warm_flag"
            ;;
        'WARM_RESTART_ENABLE_TABLE|late:enable')
            echo false
            ;;
        'FAST_RESTART_ENABLE_TABLE|system:enable')
            echo false
            ;;
        'WARM_RESTART_TABLE|latecomp:state')
            cat "$STATE_ROOT/latecomp_state"
            ;;
        *)
            echo reconciled
            ;;
    esac
    exit 0
fi

exit 0
STUB

cat > "$fixture_dir/bin/config" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "warm_restart" && "${2:-}" == "disable" ]]; then
    printf '%s\n' false > "$STATE_ROOT/global_warm_flag"
    echo "FINALIZE_COMMAND=config warm_restart disable" >> "$STATE_ROOT/events.log"
    exit 0
fi
if [[ "${1:-}" == "save" ]]; then
    echo "SAVE_COMMAND=config save -y" >> "$STATE_ROOT/events.log"
    exit 0
fi
exit 0
STUB

cat > "$fixture_dir/bin/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB

cat > "$fixture_dir/bin/sonic-cfggen" <<'STUB'
#!/usr/bin/env bash
echo fixture
STUB

cat > "$fixture_dir/bin/show" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

cat > "$fixture_dir/bin/logger" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

cat > "$fixture_dir/bin/late-service" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "SERVICE_ACTION=${1:-missing}" | tee -a "$STATE_ROOT/consumer.log"
STUB

cat > "$fixture_dir/trace.sh" <<'STUB'
specula_trace_component_selected() { return 1; }
specula_trace_event() { return 0; }
STUB

chmod +x "$fixture_dir/bin/"*

run_in_fixture() {
    timeout 20s sudo -n bwrap \
        --bind / / \
        --dev-bind /dev /dev \
        --proc /proc \
        --dir /etc/sonic \
        --bind "$fixture_dir/etc-sonic" /etc/sonic \
        --ro-bind "$fixture_dir/bin/logger" /usr/bin/logger \
        --setenv PATH "$fixture_dir/bin:/usr/bin:/bin" \
        --setenv STATE_ROOT "$fixture_dir/state" \
        --setenv PLATFORM fixture \
        --setenv ASIC_TYPE vs \
        --setenv NUM_ASIC 1 \
        --setenv VERBOSE yes \
        --setenv SPECULA_TRACE_SH "$fixture_dir/trace.sh" \
        "$@"
}

run_in_fixture /bin/bash "$FINALIZER" > "$fixture_dir/finalizer.out" 2>&1 &
finalizer_pid=$!

deadline=$((SECONDS + 5))
until [[ -e "$fixture_dir/state/snapshot_observed" ]]; do
    if ((SECONDS >= deadline)); then
        echo "HARNESS_ERROR: finalizer never passed its registration snapshot"
        exit 2
    fi
    sleep 0.01
done

# Level 2 state injection. This is precisely the durable file produced by the
# public package-manager sequence cited above; the component's State DB value
# remains "restoring", so it has not satisfied the barrier.
printf '%s\n' latecomp > "$fixture_dir/etc-sonic/late_reconcile"
: > "$fixture_dir/state/registration_injected"
echo "LEVEL2: injected reachable late registration after startup snapshot: late_reconcile=latecomp"

set +e
wait "$finalizer_pid"
finalizer_rc=$?
set -e
if ((finalizer_rc != 0)); then
    finalizer_pid=
    cat "$fixture_dir/finalizer.out"
    echo "HARNESS_ERROR: finalizer failed rc=$finalizer_rc"
    exit 2
fi
finalizer_pid=

echo "--- finalizer output ---"
cat "$fixture_dir/finalizer.out"
echo "--- observed state ---"
echo "LATE_REGISTRATION=$(cat "$fixture_dir/etc-sonic/late_reconcile")"
echo "LATE_COMPONENT_STATE=$(cat "$fixture_dir/state/latecomp_state")"
echo "GLOBAL_WARM_FLAG=$(cat "$fixture_dir/state/global_warm_flag")"

if grep -q 'latecomp' "$fixture_dir/finalizer.out"; then
    echo "ASSERTION_FAILED: finalizer unexpectedly waited for latecomp"
    exit 1
fi
if [[ "$(cat "$fixture_dir/state/global_warm_flag")" != false ]]; then
    echo "ASSERTION_FAILED: finalizer did not disable global warm restart"
    exit 1
fi
if [[ "$(cat "$fixture_dir/state/latecomp_state")" == reconciled ]]; then
    echo "ASSERTION_FAILED: latecomp was already reconciled"
    exit 1
fi

# Execute a real in-tree consumer after finalization. Its basename determines
# SERVICE=late, and /usr/bin/late.sh records whether the production consumer
# chose ordinary stop (bad) or warm kill (expected).
cp "$CONSUMER" "$fixture_dir/late.sh"
chmod +x "$fixture_dir/late.sh"
: > "$fixture_dir/state/consumer.log"
run_in_fixture \
    --ro-bind "$fixture_dir/bin/late-service" /usr/bin/late.sh \
    /bin/bash "$fixture_dir/late.sh" stop > "$fixture_dir/consumer_bad.out" 2>&1
cat "$fixture_dir/consumer_bad.out"
bad_action=$(tail -n 1 "$fixture_dir/state/consumer.log")
echo "REAL_CONSUMER_BAD_OUTCOME=$bad_action"

# Counterfactual positive control: with the global flag still true, the exact
# same production consumer selects the warm kill path.
printf '%s\n' true > "$fixture_dir/state/global_warm_flag"
: > "$fixture_dir/state/consumer.log"
run_in_fixture \
    --ro-bind "$fixture_dir/bin/late-service" /usr/bin/late.sh \
    /bin/bash "$fixture_dir/late.sh" stop > "$fixture_dir/consumer_control.out" 2>&1
cat "$fixture_dir/consumer_control.out"
control_action=$(tail -n 1 "$fixture_dir/state/consumer.log")
echo "REAL_CONSUMER_EXPECTED_CONTROL=$control_action"

if [[ "$bad_action" != "SERVICE_ACTION=stop" ]]; then
    echo "ASSERTION_FAILED: consumer did not observe the premature false flag"
    exit 1
fi
if [[ "$control_action" != "SERVICE_ACTION=kill" ]]; then
    echo "ASSERTION_FAILED: positive control did not select warm behavior"
    exit 1
fi

echo "COUNTEREXAMPLE_MATCH=late required component remains restoring when global finalization disables warm restart"
echo "BUG_TRIGGERED: finalizer omitted latecomp and a real consumer selected cold stop instead of warm kill"
