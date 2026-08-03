#!/usr/bin/env python3
"""Real-code warm-reboot trace scenarios using Python's unittest framework."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path
from typing import Dict, List

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from warmreboot_trace import TraceCollector  # noqa: E402


class WarmRebootTraceScenarios(unittest.TestCase):
    artifact = Path(
        os.environ.get(
            "SPECULA_ARTIFACT",
            "/users/Pial/targets/sonic-buildimage-warmreboot",
        )
    )
    trace_dir = Path(
        os.environ.get(
            "SPECULA_TRACE_DIR",
            HERE.parent.parent / "traces",
        )
    )

    def run_scenario(
        self,
        scenario: str,
        invocations: List[Dict[str, object]],
        *,
        num_asic: int = 1,
    ) -> List[Dict[str, object]]:
        source = self.artifact / "src/sonic-utilities/scripts/fast-reboot"
        self.assertTrue(source.is_file(), source)
        output = self.trace_dir / f"{scenario}.ndjson"

        with tempfile.TemporaryDirectory(prefix="warmreboot-trace-") as temp_name:
            temp = Path(temp_name)
            command_dir = temp / "commands"
            state_dir = temp / "state"
            warm_dir = temp / "warmboot"
            command_dir.mkdir()
            state_dir.mkdir()
            warm_dir.mkdir()
            (state_dir / "warm").write_text("false\n", encoding="utf-8")
            (state_dir / "fast").write_text("false\n", encoding="utf-8")

            socket_path = temp / "trace.sock"
            collector = TraceCollector(socket_path, output, scenario)
            collector.start()
            try:
                base_env = os.environ.copy()
                base_env.update(
                    {
                        "PATH": f"{HERE / 'fakebin'}:/usr/bin:/bin",
                        "NUM_ASIC": str(num_asic),
                        "NETNS": "",
                        "DEV": "",
                        "SPECULA_TRACE_TEST_MODE": "1",
                        "SPECULA_TRACE_CLIENT": str(HERE / "warmreboot_trace.py"),
                        "SPECULA_TRACE_SOCKET": str(socket_path),
                        "SPECULA_TRACE_WARM_DIR": str(warm_dir),
                        "SPECULA_FAKE_STATE_DIR": str(state_dir),
                        "SPECULA_RESTARTCHECK_RC": "1",
                        "SPECULA_FAIL_STOP_ASIC": "1",
                    }
                )

                for index, invocation in enumerate(invocations):
                    command_name = str(invocation["command"])
                    command = command_dir / f"{index}-{command_name}"
                    command.symlink_to(source)
                    # basename($0) is the protocol request kind.  Use a second
                    # symlink layer so each process still sees the real name.
                    protocol_command = command_dir / command_name
                    if protocol_command.exists() or protocol_command.is_symlink():
                        protocol_command.unlink()
                    protocol_command.symlink_to(command)

                    env = base_env.copy()
                    stop = invocation.get("stop")
                    if stop:
                        env["SPECULA_TRACE_TEST_STOP"] = str(stop)
                    else:
                        env.pop("SPECULA_TRACE_TEST_STOP", None)
                    result = subprocess.run(
                        [str(protocol_command)],
                        env=env,
                        text=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        timeout=30,
                        check=False,
                    )
                    expected_rc = int(invocation["rc"])
                    self.assertEqual(
                        result.returncode,
                        expected_rc,
                        f"{scenario} invocation {index}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
                    )
            finally:
                collector.stop()

        self.assertFalse(collector.errors, collector.errors)
        lines = [line for line in output.read_text(encoding="utf-8").splitlines() if line]
        self.assertTrue(lines, f"empty trace: {output}")
        events = [json.loads(line) for line in lines]
        for seq, envelope in enumerate(events, start=1):
            self.assertEqual(envelope["tag"], "warmreboot")
            self.assertEqual(envelope["seq"], seq)
            self.assertGreater(envelope["ts_ns"], 1_000_000_000_000_000_000)
            self.assertIn("post", envelope["event"])
            self.assertIsInstance(envelope["pid"], int)
        return events

    @staticmethod
    def names(events: List[Dict[str, object]]) -> List[str]:
        return [str(event["event"]["name"]) for event in events]  # type: ignore[index]

    def test_normal_admission(self) -> None:
        events = self.run_scenario(
            "normal_admission",
            [{"command": "warm-reboot", "stop": "after_enable", "rc": 0}],
        )
        self.assertEqual(
            self.names(events),
            [
                "FastReboot_Request",
                "CheckWarmRestartInProgress_Admit",
                "EnableWarmRestart",
            ],
        )

    def test_signal_cancellation_and_resume(self) -> None:
        events = self.run_scenario(
            "signal_cancellation",
            [{"command": "warm-reboot", "stop": "signal_after_enable", "rc": 0}],
        )
        self.assertEqual(
            self.names(events),
            [
                "FastReboot_Request",
                "CheckWarmRestartInProgress_Admit",
                "EnableWarmRestart",
                "ClearBoot",
                "FastReboot_ContinueAfterSignal",
            ],
        )

    def test_two_owner_rejection(self) -> None:
        events = self.run_scenario(
            "two_owner_rejection",
            [
                {"command": "fast-reboot", "stop": "after_enable", "rc": 0},
                {"command": "warm-reboot", "rc": 1},
            ],
        )
        self.assertEqual(
            self.names(events),
            [
                "FastReboot_Request",
                "CheckWarmRestartInProgress_Admit",
                "EnableWarmRestart",
                "FastReboot_Request",
                "CheckWarmRestartInProgress_Reject",
            ],
        )
        self.assertEqual(events[0]["event"]["owner"], "owner_1")
        self.assertEqual(events[3]["event"]["owner"], "owner_2")

    def test_multi_asic_masked_stops(self) -> None:
        events = self.run_scenario(
            "multi_asic_masked_stops",
            [{"command": "warm-reboot", "stop": "after_masked_stops", "rc": 0}],
            num_asic=2,
        )
        names = self.names(events)
        self.assertEqual(
            names[:3],
            [
                "FastReboot_Request",
                "CheckWarmRestartInProgress_Admit",
                "EnableWarmRestart",
            ],
        )
        self.assertEqual(Counter(names[3:5]), Counter({"PauseOrchagent_IgnoreFailure": 2}))
        self.assertEqual(
            names[5:7],
            ["FastReboot_PauseOrchagentComplete", "FastReboot_BeginIrreversibleWork"],
        )
        self.assertEqual(
            Counter(names[7:9]),
            Counter(
                {
                    "StopSystemdService_Success": 1,
                    "StopSystemdService_MaskedFailure": 1,
                }
            ),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
