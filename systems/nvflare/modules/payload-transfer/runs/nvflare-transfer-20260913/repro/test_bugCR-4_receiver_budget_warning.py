#!/usr/bin/env python3
"""CR-4 reproducer: receiver budget >= tx timeout warning is false.

This uses the normal DownloadService transaction and request-handler path with
controlled time for the monitor pass. It does not inject receiver status maps or
modify the system under test.
"""

import logging
import sys
import time
from pathlib import Path
from unittest.mock import Mock, patch


OUTPUT_ROOT = Path(__file__).resolve().parents[1]
WORKTREE = OUTPUT_ROOT / "confirmation" / "CR-4" / "worktree"
sys.path.insert(0, str(WORKTREE))

from nvflare.fuel.f3.streaming import download_service as ds_module  # noqa: E402
from nvflare.fuel.f3.streaming.download_service import DownloadStatus, ProduceRC, _PropKey  # noqa: E402
from nvflare.fuel.f3.streaming.transfer_outcome import TransferOutcomeReason  # noqa: E402
from tests.unit_test.fuel.f3.streaming.download_test_utils import (  # noqa: E402
    MockDownloadable,
    make_service_no_monitor,
    pull_request,
    run_monitor_once,
)


class CapturingHandler(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.WARNING)
        self.messages = []

    def emit(self, record):
        self.messages.append(record.getMessage())


def pull_once(service, rid, requester, state, now):
    with patch.object(ds_module.time, "time", return_value=now):
        reply = service._handle_download(pull_request(rid, requester, state=state))
    return reply.payload.get(_PropKey.STATUS), reply.payload.get(_PropKey.STATE)


def main():
    logger = logging.getLogger("nvflare.fuel.f3.streaming.download_service._Transaction")
    handler = CapturingHandler()
    old_level = logger.level
    old_propagate = logger.propagate
    logger.setLevel(logging.WARNING)
    logger.propagate = False
    logger.addHandler(handler)

    try:
        service = make_service_no_monitor()
        base = time.time()

        with patch.object(ds_module.time, "time", return_value=base):
            tx_id = service.new_transaction(
                cell=Mock(),
                timeout=10.0,
                num_receivers=2,
                receiver_ids=("active", "stalled"),
                receiver_idle_timeout=10.0,
            )
            rid = service.add_object(tx_id, MockDownloadable([b"a", b"b", b"c"]))

        warning = next((m for m in handler.messages if "can never fire" in m), None)
        print(f"LEVEL0_WARNING={warning!r}")
        assert warning is not None, "expected the constructor warning under test"

        stalled_status, _ = pull_once(service, rid, "stalled", None, base)
        active_status, active_state = pull_once(service, rid, "active", None, base)
        print(f"INITIAL_PULLS stalled={stalled_status} active={active_status} active_state={active_state}")

        active_status, active_state = pull_once(service, rid, "active", active_state, base + 9.0)
        print(f"ACTIVE_REFRESH_AT_T_PLUS_9 status={active_status} active_state={active_state}")

        tx = service._tx_table[tx_id]
        tx_age_at_budget_pass = (base + 11.0) - tx.last_active_time
        print(f"TX_INACTIVITY_AT_T_PLUS_11={tx_age_at_budget_pass:.1f}s")
        assert tx_age_at_budget_pass < tx.timeout, "transaction-wide timeout should not be expired"

        run_monitor_once(service, now=base + 11.0)
        ref = service._ref_table[rid]
        statuses_after_budget = dict(ref.snapshot_receiver_statuses())
        tx_still_live = tx_id in service._tx_table
        print(f"LEVEL1_STATUSES_AFTER_BUDGET={statuses_after_budget}")
        print(f"TX_STILL_LIVE_AFTER_BUDGET={tx_still_live}")
        assert statuses_after_budget == {"stalled": DownloadStatus.FAILED}
        assert tx_still_live, "budget fired while the transaction itself remained live"

        for _ in range(10):
            active_status, active_state = pull_once(service, rid, "active", active_state, base + 12.0)
            print(f"ACTIVE_FINISH_PULL status={active_status} active_state={active_state}")
            if active_status == ProduceRC.EOF:
                break
        assert active_status == ProduceRC.EOF, "active receiver should be able to finish normally"

        run_monitor_once(service, now=base + 12.1)
        with patch.object(ds_module.time, "time", return_value=base + 12.2):
            outcome = service.get_transaction_outcome(tx_id)
        assert outcome is not None, "finished transaction should have a recorded outcome"

        final_statuses = dict(outcome.refs[0].receiver_statuses)
        print(f"FINAL_OUTCOME_COMPLETED={outcome.completed}")
        print(f"FINAL_OUTCOME_REASON={outcome.reason}")
        print(f"FINAL_OUTCOME_STATUSES={final_statuses}")

        assert outcome.completed is False
        assert outcome.reason == TransferOutcomeReason.RECEIVER_FAILED
        assert final_statuses == {"stalled": DownloadStatus.FAILED, "active": DownloadStatus.SUCCESS}

        print("RESULT=DIAGNOSTIC_REPRODUCED_TRANSFER_OUTCOME_CORRECT")
    finally:
        logger.removeHandler(handler)
        logger.setLevel(old_level)
        logger.propagate = old_propagate


if __name__ == "__main__":
    main()
