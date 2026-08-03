#!/usr/bin/env python3
"""Reproduce MC-6's timeout transition and prove the current downstream mask.

Level 0/1 require a SONiC runtime, which the confirmation host does not expose.
Level 2 runs the unmodified finalizer entry point against the public command/DB
boundary with the exact reachable states represented by CE states 4-6.  The
five-minute delay is collapsed, but all 60 polls and finalizer branches remain.
"""

from __future__ import annotations

import contextlib
import fnmatch
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import types


TEST_PATH = Path(__file__).resolve()
OUTPUT_ROOT = TEST_PATH.parent.parent
REPO = OUTPUT_ROOT / "confirmation" / "MC-6" / "worktree"
FINALIZER = REPO / "files/image_config/warmboot-finalizer/finalize-warmboot.sh"
XCVRD_COMMON = (
    REPO
    / "src/sonic-platform-daemons/sonic-xcvrd/xcvrd/xcvrd_utilities/common.py"
)
XCVRD_MAIN = REPO / "src/sonic-platform-daemons/sonic-xcvrd/xcvrd/xcvrd.py"
SHOW_WARM_RESTART = REPO / "src/sonic-utilities/show/warm_restart.py"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def write_executable(path: Path, content: str) -> None:
    path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


@contextlib.contextmanager
def installed_modules(modules: dict[str, types.ModuleType]):
    old = {name: sys.modules.get(name) for name in modules}
    sys.modules.update(modules)
    try:
        yield
    finally:
        for name, previous in old.items():
            if previous is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = previous


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def run_current_xcvrd_guard(state: dict) -> bool:
    """Execute current xcvrd's real is_syncd_warm_restore_complete()."""

    class StateDB:
        def hget(self, table: str, field: str):
            return state.get(table, {}).get(field)

    class SilentLogger:
        def __init__(self, *_args, **_kwargs):
            pass

        def __getattr__(self, _name):
            return lambda *_args, **_kwargs: None

    swss_inner = types.ModuleType("swsscommon.swsscommon")
    swss_inner.FieldValuePairs = lambda value: value
    swss_package = types.ModuleType("swsscommon")
    swss_package.swsscommon = swss_inner

    syslogger = types.ModuleType("sonic_py_common.syslogger")
    syslogger.SysLogger = SilentLogger
    daemon_base = types.ModuleType("sonic_py_common.daemon_base")
    daemon_base.db_connect = lambda *_args, **_kwargs: StateDB()
    multi_asic = types.ModuleType("sonic_py_common.multi_asic")
    multi_asic.is_multi_asic = lambda: False
    sonic_py_common = types.ModuleType("sonic_py_common")
    sonic_py_common.syslogger = syslogger
    sonic_py_common.daemon_base = daemon_base
    sonic_py_common.multi_asic = multi_asic

    xcvrd_package = types.ModuleType("xcvrd")
    xcvrd_package.__path__ = []
    utilities_package = types.ModuleType("xcvrd.xcvrd_utilities")
    utilities_package.__path__ = []
    sfp_status = types.ModuleType("xcvrd.xcvrd_utilities.sfp_status_helper")

    platform_base = types.ModuleType("sonic_platform_base")
    platform_base.__path__ = []
    sonic_xcvr = types.ModuleType("sonic_platform_base.sonic_xcvr")
    sonic_xcvr.__path__ = []
    api = types.ModuleType("sonic_platform_base.sonic_xcvr.api")
    api.__path__ = []
    public = types.ModuleType("sonic_platform_base.sonic_xcvr.api.public")
    public.__path__ = []
    c_cmis = types.ModuleType("sonic_platform_base.sonic_xcvr.api.public.c_cmis")
    c_cmis.CmisApi = type("CmisApi", (), {})

    modules = {
        "swsscommon": swss_package,
        "swsscommon.swsscommon": swss_inner,
        "sonic_py_common": sonic_py_common,
        "sonic_py_common.syslogger": syslogger,
        "sonic_py_common.daemon_base": daemon_base,
        "sonic_py_common.multi_asic": multi_asic,
        "xcvrd": xcvrd_package,
        "xcvrd.xcvrd_utilities": utilities_package,
        "xcvrd.xcvrd_utilities.sfp_status_helper": sfp_status,
        "sonic_platform_base": platform_base,
        "sonic_platform_base.sonic_xcvr": sonic_xcvr,
        "sonic_platform_base.sonic_xcvr.api": api,
        "sonic_platform_base.sonic_xcvr.api.public": public,
        "sonic_platform_base.sonic_xcvr.api.public.c_cmis": c_cmis,
    }

    with installed_modules(modules):
        spec = importlib.util.spec_from_file_location(
            "xcvrd.xcvrd_utilities.common", XCVRD_COMMON
        )
        require(spec is not None and spec.loader is not None, "cannot load xcvrd common")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        try:
            spec.loader.exec_module(module)
            return bool(module.is_syncd_warm_restore_complete(""))
        finally:
            sys.modules.pop(spec.name, None)


def run_show_warm_restart_state(state: dict) -> str:
    """Execute the pinned show command's state projection with a DB adapter."""

    class StateConnector:
        STATE_DB = "STATE_DB"

        def __init__(self, **_kwargs):
            pass

        def connect(self, *_args, **_kwargs):
            return None

        def keys(self, _db, pattern: str):
            return sorted(k for k in state if fnmatch.fnmatch(k, pattern))

        def get_all(self, _db, key: str):
            return dict(state.get(key, {}))

        def get(self, _db, key: str, field: str):
            return state.get(key, {}).get(field)

        def close(self, *_args, **_kwargs):
            return None

    class ConfigConnector:
        def __init__(self, **_kwargs):
            pass

        def connect(self, **_kwargs):
            return None

        def get_table(self, _name: str):
            return {}

    class DummyGroup:
        def __init__(self, function):
            self.function = function

        def command(self, *_args, **_kwargs):
            return lambda function: function

    click = types.ModuleType("click")
    click.group = lambda *_args, **_kwargs: lambda function: DummyGroup(function)
    click.option = lambda *_args, **_kwargs: lambda function: function
    click.echo = print
    click.secho = lambda message, **_kwargs: print(message)
    click.UsageError = RuntimeError

    tabulate_module = types.ModuleType("tabulate")
    tabulate_module.tabulate = lambda rows, header: "\n".join(
        [" | ".join(header)] + [" | ".join(str(value) for value in row) for row in rows]
    )

    utilities_common = types.ModuleType("utilities_common")
    utilities_common.__path__ = []
    cli = types.ModuleType("utilities_common.cli")
    cli.AliasedGroup = type("AliasedGroup", (), {})
    multi_asic_util = types.ModuleType("utilities_common.multi_asic")
    multi_asic_util.constants = types.SimpleNamespace(DEFAULT_NAMESPACE="")
    utilities_common.cli = cli
    utilities_common.multi_asic = multi_asic_util

    multi_asic = types.ModuleType("sonic_py_common.multi_asic")
    multi_asic.get_namespace_list = lambda: []
    multi_asic.is_multi_asic = lambda: False
    sonic_py_common = types.ModuleType("sonic_py_common")
    sonic_py_common.multi_asic = multi_asic

    swss_inner = types.ModuleType("swsscommon.swsscommon")
    swss_inner.SonicV2Connector = StateConnector
    swss_inner.ConfigDBConnector = ConfigConnector
    swss_package = types.ModuleType("swsscommon")
    swss_package.swsscommon = swss_inner

    modules = {
        "click": click,
        "tabulate": tabulate_module,
        "utilities_common": utilities_common,
        "utilities_common.cli": cli,
        "utilities_common.multi_asic": multi_asic_util,
        "sonic_py_common": sonic_py_common,
        "sonic_py_common.multi_asic": multi_asic,
        "swsscommon": swss_package,
        "swsscommon.swsscommon": swss_inner,
    }
    with installed_modules(modules):
        spec = importlib.util.spec_from_file_location("mc6_show_warm_restart", SHOW_WARM_RESTART)
        require(spec is not None and spec.loader is not None, "cannot load show command")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            module.show_warm_restart_state_for_namespace(None)
        return output.getvalue().strip()


def make_command_stubs(bin_dir: Path, state_path: Path) -> None:
    write_executable(
        bin_dir / "sonic-db-cli",
        r'''
        #!/usr/bin/env python3
        import fcntl
        import json
        import os
        from pathlib import Path
        import sys

        state_path = Path(os.environ["MC6_STATE"])

        def access(write=False, callback=None):
            with state_path.open("r+", encoding="utf-8") as stream:
                fcntl.flock(stream, fcntl.LOCK_EX if write else fcntl.LOCK_SH)
                data = json.load(stream)
                result = callback(data) if callback else None
                if write:
                    stream.seek(0)
                    json.dump(data, stream, sort_keys=True)
                    stream.truncate()
                fcntl.flock(stream, fcntl.LOCK_UN)
                return result

        args = sys.argv[1:]
        if len(args) >= 2 and args[0] == "-n":
            args = args[2:]
        if args == ["PING"]:
            print("PONG")
            raise SystemExit(0)
        if len(args) < 2:
            raise SystemExit("unsupported sonic-db-cli call: " + repr(args))

        database, command, rest = args[0], args[1].upper(), args[2:]
        if database == "CONFIG_DB" and command == "GET" and rest == ["CONFIG_DB_INITIALIZED"]:
            print("1")
        elif command == "HGET" and len(rest) == 2:
            key, field = rest
            value = access(callback=lambda data: data.get(key, {}).get(field, ""))
            if value is not None:
                print(value)
        elif command == "HSET" and len(rest) == 3:
            key, field, value = rest
            def update(data):
                data.setdefault(key, {})[field] = value
                data.setdefault("_events", []).append(f"{database}:HSET:{key}:{field}={value}")
            access(write=True, callback=update)
            print("1")
        elif command == "DEL" and len(rest) == 1:
            key = rest[0]
            def delete(data):
                data.pop(key, None)
                data.setdefault("_events", []).append(f"{database}:DEL:{key}")
            access(write=True, callback=delete)
            print("1")
        else:
            raise SystemExit("unsupported sonic-db-cli call: " + repr(args))
        ''',
    )
    write_executable(
        bin_dir / "config",
        r'''
        #!/usr/bin/env python3
        import fcntl
        import json
        import os
        from pathlib import Path
        import sys

        state_path = Path(os.environ["MC6_STATE"])
        args = sys.argv[1:]
        with state_path.open("r+", encoding="utf-8") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            data = json.load(stream)
            if args[:2] == ["warm_restart", "disable"]:
                data.setdefault("WARM_RESTART_ENABLE_TABLE|system", {})["enable"] = "false"
                data.setdefault("_events", []).append("config:warm_restart:disable:system")
            elif args[:1] == ["save"]:
                data.setdefault("_events", []).append("config:save")
            else:
                raise SystemExit("unsupported config call: " + repr(args))
            stream.seek(0)
            json.dump(data, stream, sort_keys=True)
            stream.truncate()
            fcntl.flock(stream, fcntl.LOCK_UN)
        ''',
    )
    write_executable(
        bin_dir / "sudo",
        r'''
        #!/usr/bin/env python3
        import os
        import sys
        os.execvp(sys.argv[1], sys.argv[1:])
        ''',
    )
    write_executable(bin_dir / "sleep", "#!/bin/sh\nexit 0\n")
    write_executable(bin_dir / "find", "#!/bin/sh\nexit 0\n")
    write_executable(bin_dir / "sonic-cfggen", "#!/bin/sh\nprintf '%s\\n' generic\n")


def main() -> int:
    for source in (FINALIZER, XCVRD_COMMON, XCVRD_MAIN, SHOW_WARM_RESTART):
        require(source.is_file(), f"missing source artifact: {source}")

    repo_commit = subprocess.check_output(
        ["git", "-C", str(REPO), "rev-parse", "HEAD"], text=True
    ).strip()
    xcvrd_commit = subprocess.check_output(
        ["git", "-C", str(REPO / "src/sonic-platform-daemons"), "rev-parse", "HEAD"],
        text=True,
    ).strip()
    finalizer_hash = hashlib.sha256(FINALIZER.read_bytes()).hexdigest()

    print(f"SOURCE_REPO_COMMIT={repo_commit}")
    print(f"XCVRD_SUBMODULE_COMMIT={xcvrd_commit}")
    print(f"FINALIZER_SHA256={finalizer_hash}")

    real_cli = shutil.which("sonic-db-cli")
    if real_cli is None:
        print("LEVEL0=UNAVAILABLE (host has no sonic-db-cli/SONiC runtime)")
        print("LEVEL1=UNAVAILABLE (timing assistance alone cannot supply the missing runtime)")
    else:
        print(f"LEVEL0=NOT_RUN_SAFELY (live CLI found at {real_cli}; test will not mutate host DB)")
        print("LEVEL1=NOT_RUN_SAFELY (timing-only live-host mutation deliberately avoided)")

    with tempfile.TemporaryDirectory(prefix="mc6-finalizer-") as temporary:
        temp_dir = Path(temporary)
        bin_dir = temp_dir / "bin"
        bin_dir.mkdir()
        state_path = temp_dir / "state.json"
        initial_state = {
            "FEATURE|swss": {
                "state": "enabled",
                "has_per_asic_scope": "true",
                "has_global_scope": "false",
            },
            "FEATURE|bgp": {
                "state": "enabled",
                "has_per_asic_scope": "false",
                "has_global_scope": "true",
            },
            "FEATURE|nat": {
                "state": "disabled",
                "has_per_asic_scope": "false",
                "has_global_scope": "true",
            },
            "FEATURE|mux": {
                "state": "disabled",
                "has_per_asic_scope": "false",
                "has_global_scope": "true",
            },
            "WARM_RESTART_ENABLE_TABLE|system": {"enable": "true"},
            "FAST_RESTART_ENABLE_TABLE|system": {"enable": "true"},
            "WARM_RESTART_TABLE|orchagent": {"restore_count": "1", "state": "initialized"},
            "WARM_RESTART_TABLE|neighsyncd": {"restore_count": "1", "state": "reconciled"},
            "WARM_RESTART_TABLE|bgp": {"restore_count": "1", "state": "restored"},
            "WARM_RESTART_TABLE|syncd": {"restore_count": "1", "state": "reconciled"},
            "_events": [],
        }
        state_path.write_text(json.dumps(initial_state, sort_keys=True), encoding="utf-8")
        make_command_stubs(bin_dir, state_path)

        env = os.environ.copy()
        env.update(
            {
                "PATH": str(bin_dir) + os.pathsep + env.get("PATH", ""),
                "MC6_STATE": str(state_path),
                "VERBOSE": "yes",
                "PLATFORM": "mc6-test-platform",
                "NUM_ASIC": "1",
                "ASIC_TYPE": "generic",
            }
        )
        completed = subprocess.run(
            ["bash", str(FINALIZER)],
            env=env,
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )
        require(completed.returncode == 0, f"finalizer returned {completed.returncode}: {completed.stderr}")
        timeout_lines = [
            line.strip()
            for line in completed.stdout.splitlines()
            if "Some components didn't finish reconcile" in line
        ]
        require(any("orchagent" in line for line in timeout_lines), "orchagent timeout was not reached")
        require(any("bgp" in line for line in timeout_lines), "bgp/fpmsyncd timeout was not reached")

        final_state = load_json(state_path)
        warm_flag = final_state["WARM_RESTART_ENABLE_TABLE|system"]["enable"]
        fast_flag = final_state["FAST_RESTART_ENABLE_TABLE|system"]["enable"]
        orch_state = final_state["WARM_RESTART_TABLE|orchagent"]["state"]
        bgp_state = final_state["WARM_RESTART_TABLE|bgp"]["state"]
        require(warm_flag == "false" and fast_flag == "false", "finalizer did not clear both flags")
        require(orch_state == "initialized", "injected orchagent state unexpectedly changed")
        require(bgp_state == "restored", "injected fpmsyncd/bgp state unexpectedly changed")

        print("LEVEL2=EXECUTED (CE states 4-6 via normal finalizer command boundary; sleep only collapsed)")
        for line in sorted(timeout_lines):
            marker = line.split("- ", 1)[-1]
            print(f"FINALIZER_LOG={marker}")
        print(f"AFTER_TIMEOUT warm={warm_flag} fast={fast_flag} orchagent={orch_state} fpmsyncd_as_bgp={bgp_state}")
        print("FINALIZER_EVENTS=" + ",".join(final_state.get("_events", [])))

        shown = run_show_warm_restart_state(final_state)
        require("orchagent | 1 | initialized" in shown, "show command lost orchagent state")
        require("bgp | 1 | restored" in shown, "show command lost bgp state")
        print("SHOW_WARM_RESTART_STATE_BEGIN")
        print(shown)
        print("SHOW_WARM_RESTART_STATE_END")

        old_flag_only_result = warm_flag == "true"
        current_xcvrd_result = run_current_xcvrd_guard(final_state)
        require(old_flag_only_result is False, "historical flag-only consumer unexpectedly sees warm")
        require(current_xcvrd_result is True, "current xcvrd restore_count safeguard did not fire")

        xcvrd_source = XCVRD_MAIN.read_text(encoding="utf-8")
        require(
            "common.is_syncd_warm_restore_complete(namespace)" in xcvrd_source,
            "current xcvrd does not call the tested safeguard",
        )
        require(
            "if is_warm_start == False:" in xcvrd_source
            and "media_settings_parser.notify_media_setting" in xcvrd_source,
            "xcvrd media-setting consumer branch changed",
        )
        print(f"HISTORICAL_FLAG_ONLY_WARM={str(old_flag_only_result).lower()}")
        print(f"CURRENT_XCVRD_WARM_GUARD={str(current_xcvrd_result).lower()}")
        print("CURRENT_XCVRD_NOTIFY_BRANCH_TAKEN=false")
        print("MASK=syncd.restore_count remains 1, so current xcvrd suppresses premature media-setting publish")
        print("LEVEL3=NOT_REACHED (Level 2 reproduced the transition and proved the downstream mask)")
        print("TEST_RESULT=PASS (timeout/clear transition reproduced; claimed live harm is masked in pinned code)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"TEST_RESULT=FAIL ({type(error).__name__}: {error})", file=sys.stderr)
        raise
