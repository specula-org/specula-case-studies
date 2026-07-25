#!/usr/bin/env python3
"""patch_sources.py — Inserts TLA+ trace emit() calls into MongoDB range deletion source files.

Run from apply.sh; argument is the src/mongo/db/s/ directory.
Each edit is idempotent: re-running is a no-op if already patched.
"""

import sys
import re

SRC = sys.argv[1]


def read(path):
    with open(path) as f:
        return f.read()


def write(path, text):
    with open(path, "w") as f:
        f.write(text)
    print(f"  patched {path.split('/')[-1]}")


def already(text, marker):
    return marker in text


# ─────────────────────────────────────────────────────────────────────────────
# migration_coordinator.cpp
# ─────────────────────────────────────────────────────────────────────────────

MC = f"{SRC}/migration_coordinator.cpp"
mc = read(MC)

if not already(mc, '#include "tla_trace.h"'):
    mc = mc.replace(
        '#include "mongo/db/s/migration_coordinator.h"',
        '#include "mongo/db/s/migration_coordinator.h"\n#include "tla_trace.h"',
        1,
    )

# 1. WriteCoordDoc — after insertMigrationCoordinatorDoc
EMIT_WRITE_COORD = '''\
    tla_trace::emit("WriteCoordDoc", _migrationInfo.getId().toString(),
                    "present", "absent", "absent", true);'''
if not already(mc, '"WriteCoordDoc"'):
    mc = mc.replace(
        "    migrationutil::insertMigrationCoordinatorDoc(opCtx, _migrationInfo);\n",
        "    migrationutil::insertMigrationCoordinatorDoc(opCtx, _migrationInfo);\n"
        + EMIT_WRITE_COORD + "\n",
        1,
    )

# 2. WriteRangeDeletionTask — after _donorRangeDeletionTask.emplace(...)
EMIT_WRITE_RDT = '''\
    tla_trace::emit("WriteRangeDeletionTask", _migrationInfo.getId().toString(),
                    "present", "pending", "pending", true);'''
if not already(mc, '"WriteRangeDeletionTask"'):
    # Insert after the closing paren of _donorRangeDeletionTask.emplace(...))
    mc = mc.replace(
        "        defaultMajorityWriteConcernDoNotUse()));\n}\n\nvoid MigrationCoordinator::setMigrationDecision",
        "        defaultMajorityWriteConcernDoNotUse()));\n"
        + EMIT_WRITE_RDT + "\n}\n\nvoid MigrationCoordinator::setMigrationDecision",
        1,
    )

# 3. PersistCommitDecision — after persistCommitDecision
EMIT_COMMIT = '''\
    tla_trace::emit("PersistCommitDecision", _migrationInfo.getId().toString(),
                    "committed", "pending", "pending", true);'''
if not already(mc, '"PersistCommitDecision"'):
    mc = mc.replace(
        "    migrationutil::persistCommitDecision(opCtx, _migrationInfo);\n",
        "    migrationutil::persistCommitDecision(opCtx, _migrationInfo);\n"
        + EMIT_COMMIT + "\n",
        1,
    )

# 4. DeleteRecipientTaskOnCommit — after deleteRangeDeletionTaskOnRecipient
EMIT_DEL_RECIP = '''\
    tla_trace::emit("DeleteRecipientTaskOnCommit", _migrationInfo.getId().toString(),
                    "committed", "pending", "absent", true);'''
if not already(mc, '"DeleteRecipientTaskOnCommit"'):
    mc = mc.replace(
        "                                                          _migrationInfo.getId());\n"
        "    // We only expect",
        "                                                          _migrationInfo.getId());\n"
        + EMIT_DEL_RECIP + "\n"
        "    // We only expect",
        1,
    )

# 5. ActivateDonorTaskOnCommit — after markAsReadyRangeDeletionTaskLocally
EMIT_ACTIVATE = '''\
    tla_trace::emit("ActivateDonorTaskOnCommit", _migrationInfo.getId().toString(),
                    "committed", "ready", "absent", true);'''
if not already(mc, '"ActivateDonorTaskOnCommit"'):
    mc = mc.replace(
        "    rangedeletionutil::markAsReadyRangeDeletionTaskLocally(\n"
        "        opCtx, _donorRangeDeletionTask->getCollectionUuid(), _donorRangeDeletionTask->getRange());\n"
        "\n    return rangeDeletionCompletionFuture;",
        "    rangedeletionutil::markAsReadyRangeDeletionTaskLocally(\n"
        "        opCtx, _donorRangeDeletionTask->getCollectionUuid(), _donorRangeDeletionTask->getRange());\n"
        + EMIT_ACTIVATE + "\n"
        "\n    return rangeDeletionCompletionFuture;",
        1,
    )

# 6. PersistAbortDecision — after persistAbortDecision
EMIT_ABORT = '''\
    tla_trace::emit("PersistAbortDecision", _migrationInfo.getId().toString(),
                    "aborted", "pending", "pending", true);'''
if not already(mc, '"PersistAbortDecision"'):
    mc = mc.replace(
        "    migrationutil::persistAbortDecision(opCtx, _migrationInfo);\n",
        "    migrationutil::persistAbortDecision(opCtx, _migrationInfo);\n"
        + EMIT_ABORT + "\n",
        1,
    )

# 7. DeleteDonorTaskOnAbort — after deleteRangeDeletionTaskLocally
EMIT_DEL_DONOR = '''\
    tla_trace::emit("DeleteDonorTaskOnAbort", _migrationInfo.getId().toString(),
                    "aborted", "absent", "pending", true);'''
if not already(mc, '"DeleteDonorTaskOnAbort"'):
    mc = mc.replace(
        "                                                      _migrationInfo.getRange(),\n"
        "                                                      defaultMajorityWriteConcernDoNotUse());\n"
        "\n    try {",
        "                                                      _migrationInfo.getRange(),\n"
        "                                                      defaultMajorityWriteConcernDoNotUse());\n"
        + EMIT_DEL_DONOR + "\n"
        "\n    try {",
        1,
    )

# 8. MarkRecipientTaskReady — after markAsReadyRangeDeletionTaskOnRecipient
EMIT_MARK_RECIP = '''\
    tla_trace::emit("MarkRecipientTaskReady", _migrationInfo.getId().toString(),
                    "aborted", "absent", "ready", true);'''
if not already(mc, '"MarkRecipientTaskReady"'):
    mc = mc.replace(
        "    rangedeletionutil::markAsReadyRangeDeletionTaskOnRecipient(opCtx,\n"
        "                                                               _migrationInfo.getRecipientShardId(),\n"
        "                                                               _migrationInfo.getCollectionUuid(),\n"
        "                                                               _migrationInfo.getRange(),\n"
        "                                                               _migrationInfo.getId());\n"
        "}",
        "    rangedeletionutil::markAsReadyRangeDeletionTaskOnRecipient(opCtx,\n"
        "                                                               _migrationInfo.getRecipientShardId(),\n"
        "                                                               _migrationInfo.getCollectionUuid(),\n"
        "                                                               _migrationInfo.getRange(),\n"
        "                                                               _migrationInfo.getId());\n"
        + EMIT_MARK_RECIP + "\n"
        "}",
        1,
    )

# 9. ForgetMigration — after store.remove
EMIT_FORGET = """\
    // TLA+ trace: ForgetMigration — w:1 remove, may roll back on stepdown
    {
        auto _tlaDec = _migrationInfo.getDecision();
        bool _tlaCommit = _tlaDec && (*_tlaDec == DecisionEnum::kCommitted);
        bool _tlaDonorWritten = _donorRangeDeletionTask.has_value();
        std::string _tlaDonor = (!_tlaDonorWritten) ? "absent" : (_tlaCommit ? "ready" : "absent");
        std::string _tlaRecip = _tlaCommit ? "absent" : "ready";
        tla_trace::emit("ForgetMigration", _migrationInfo.getId().toString(),
                        "absent", _tlaDonor, _tlaRecip, true);
    }"""
if not already(mc, '"ForgetMigration"'):
    mc = mc.replace(
        "                 WriteConcernOptions{1, WriteConcernOptions::SyncMode::UNSET, Seconds(0)});\n"
        "}",
        "                 WriteConcernOptions{1, WriteConcernOptions::SyncMode::UNSET, Seconds(0)});\n"
        + EMIT_FORGET + "\n"
        "}",
        1,
    )

write(MC, mc)

# ─────────────────────────────────────────────────────────────────────────────
# ready_range_deletions_processor.cpp
# ─────────────────────────────────────────────────────────────────────────────

RDP = f"{SRC}/ready_range_deletions_processor.cpp"
rdp = read(RDP)

if not already(rdp, '#include "tla_trace.h"'):
    rdp = rdp.replace(
        '#include "mongo/db/s/ready_range_deletions_processor.h"',
        '#include "mongo/db/s/ready_range_deletions_processor.h"\n#include "tla_trace.h"',
        1,
    )

# ExecuteRangeDeletion — before deleteRangeInBatches, after the LOGV2_INFO at line ~262
EMIT_EXECUTE = '''\
                        // TLA+ trace: ExecuteRangeDeletion
                        tla_trace::emit("ExecuteRangeDeletion", task.getId().toString(),
                                        "absent", "processing", "absent", true);'''
if not already(rdp, '"ExecuteRangeDeletion"'):
    rdp = rdp.replace(
        '                        LOGV2_INFO(6872501,\n'
        '                                   "Beginning deletion of documents in orphan range",\n'
        '                                   "namespace"_attr = nss,\n'
        '                                   "collectionUUID"_attr = collectionUuid.toString(),\n'
        '                                   "range"_attr = redact(range.toString()));\n',
        '                        LOGV2_INFO(6872501,\n'
        '                                   "Beginning deletion of documents in orphan range",\n'
        '                                   "namespace"_attr = nss,\n'
        '                                   "collectionUUID"_attr = collectionUuid.toString(),\n'
        '                                   "range"_attr = redact(range.toString()));\n'
        + EMIT_EXECUTE + "\n",
        1,
    )

# CompleteRangeDeletion — after removePersistentTask
EMIT_COMPLETE = '''\
                        // TLA+ trace: CompleteRangeDeletion
                        tla_trace::emit("CompleteRangeDeletion", task->getId().toString(),
                                        "absent", "absent", "absent", true);'''
if not already(rdp, '"CompleteRangeDeletion"'):
    rdp = rdp.replace(
        "                    auto task = self->completeTask(collectionUuid, range);\n"
        "                    if (task) {\n"
        "                        rangedeletionutil::removePersistentTask(opCtx, task->getTaskId());\n"
        "                    }",
        "                    auto task = self->completeTask(collectionUuid, range);\n"
        "                    if (task) {\n"
        "                        rangedeletionutil::removePersistentTask(opCtx, task->getTaskId());\n"
        + EMIT_COMPLETE + "\n"
        "                    }",
        1,
    )

write(RDP, rdp)

# ─────────────────────────────────────────────────────────────────────────────
# range_deleter_service.cpp
# ─────────────────────────────────────────────────────────────────────────────

RDS = f"{SRC}/range_deleter_service.cpp"
rds = read(RDS)

if not already(rds, '#include "tla_trace.h"'):
    rds = rds.replace(
        '#include "mongo/db/s/range_deleter_service.h"',
        '#include "mongo/db/s/range_deleter_service.h"\n#include "tla_trace.h"',
        1,
    )

# Recovery — after notifyRecoveryJobComplete(term)
EMIT_RECOVERY = '''\
            // TLA+ trace: Recovery — all tasks re-registered after step-up
            tla_trace::emit("Recovery", "*", "absent", "absent", "absent", true);'''
if not already(rds, '"Recovery"'):
    rds = rds.replace(
        "            notifyRecoveryJobComplete(term);\n"
        "        })\n"
        "        .getAsync([](auto) {});",
        "            notifyRecoveryJobComplete(term);\n"
        + EMIT_RECOVERY + "\n"
        "        })\n"
        "        .getAsync([](auto) {});",
        1,
    )

write(RDS, rds)

print("All source files patched successfully.")
