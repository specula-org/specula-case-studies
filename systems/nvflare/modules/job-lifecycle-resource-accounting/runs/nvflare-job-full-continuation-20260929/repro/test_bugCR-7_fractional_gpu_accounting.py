#!/usr/bin/env python3
"""Reproduce CR-7 via GPUResourceManager's public check/allocate/free API."""

from __future__ import annotations

import json
import sys
from pathlib import Path


SOURCE_ROOT = Path(
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/"
    "nvflare-job/.specula-output/confirmation/CR-7/worktree"
).resolve()

sys.path.insert(0, str(SOURCE_ROOT))

import nvflare  # noqa: E402
from nvflare.apis.fl_context import FLContext, FLContextManager  # noqa: E402
from nvflare.app_common.resource_managers.gpu_resource_manager import GPUResourceManager  # noqa: E402


NUM_GPU_KEY = "num_of_gpus"
GPU_MEM_KEY = "mem_per_gpu_in_GiB"
FULL = {NUM_GPU_KEY: 1, GPU_MEM_KEY: 1.0}


class MockEngine:
    def __init__(self, run_name: str = "cr7-repro"):
        self.fl_ctx_mgr = FLContextManager(
            engine=self,
            identity_name="__cr7_repro",
            job_id=run_name,
            public_stickers={},
            private_stickers={},
        )

    def new_context(self):
        return self.fl_ctx_mgr.new_context()

    def fire_event(self, event_type: str, fl_ctx: FLContext):
        pass


def requirement(gpu_mem: float) -> dict:
    return {NUM_GPU_KEY: 1, GPU_MEM_KEY: gpu_mem}


def make_manager() -> GPUResourceManager:
    return GPUResourceManager(
        num_of_gpus=1,
        mem_per_gpu_in_GiB=1.0,
        expiration_period=30,
        ignore_host=True,
    )


def report_memory(manager: GPUResourceManager, engine: MockEngine) -> float:
    with engine.new_context() as fl_ctx:
        report = manager.report_resources(fl_ctx)
    return report["resources"][0]["memory"]


def check_only(manager: GPUResourceManager, engine: MockEngine, req: dict) -> tuple[bool, str]:
    with engine.new_context() as fl_ctx:
        ok, token = manager.check_resources(resource_requirement=req, fl_ctx=fl_ctx)
    return ok, token


def cancel_if_reserved(manager: GPUResourceManager, engine: MockEngine, req: dict, ok: bool, token: str):
    if ok and token:
        with engine.new_context() as fl_ctx:
            manager.cancel_resources(resource_requirement=req, token=token, fl_ctx=fl_ctx)


def allocate_checked(manager: GPUResourceManager, engine: MockEngine, req: dict) -> tuple[str, dict]:
    ok, token = check_only(manager, engine, req)
    if not ok:
        raise AssertionError(f"precondition failed: expected request {req} to reserve successfully")
    with engine.new_context() as fl_ctx:
        resources = manager.allocate_resources(resource_requirement=req, token=token, fl_ctx=fl_ctx)
    return token, resources


def free_allocated(manager: GPUResourceManager, engine: MockEngine, resources: dict, token: str):
    with engine.new_context() as fl_ctx:
        manager.free_resources(resources=resources, token=token, fl_ctx=fl_ctx)


def fresh_full_capacity_control() -> dict:
    engine = MockEngine("fresh-full-control")
    manager = make_manager()
    ok, token = check_only(manager, engine, FULL)
    memory_after_check = report_memory(manager, engine)
    cancel_if_reserved(manager, engine, FULL, ok, token)
    return {
        "full_request_ok": ok,
        "memory_after_check_repr": repr(memory_after_check),
        "memory_after_cancel_repr": repr(report_memory(manager, engine)),
    }


def fractional_sequence(first: float, second: float, free_order: str) -> dict:
    engine = MockEngine(f"fractional-{first}-{second}-{free_order}")
    manager = make_manager()
    req1 = requirement(first)
    req2 = requirement(second)

    token1, resources1 = allocate_checked(manager, engine, req1)
    token2, resources2 = allocate_checked(manager, engine, req2)

    frees = [(token1, resources1), (token2, resources2)]
    if free_order == "reverse":
        frees.reverse()
    elif free_order != "fifo":
        raise ValueError(f"unexpected free order {free_order!r}")

    for token, resources in frees:
        free_allocated(manager, engine, resources, token)

    restored_memory = report_memory(manager, engine)
    full_ok, full_token = check_only(manager, engine, FULL)
    cancel_if_reserved(manager, engine, FULL, full_ok, full_token)
    return {
        "allocated": [resources1, resources2],
        "free_order": free_order,
        "restored_memory_repr": repr(restored_memory),
        "restored_memory": restored_memory,
        "full_request_after_free_ok": full_ok,
        "memory_after_final_check_repr": repr(report_memory(manager, engine)),
    }


def main():
    nvflare_file = Path(nvflare.__file__).resolve()
    if SOURCE_ROOT not in nvflare_file.parents:
        raise RuntimeError(f"imported nvflare from {nvflare_file}, expected under {SOURCE_ROOT}")

    fresh_control = fresh_full_capacity_control()
    exact_fraction_control = fractional_sequence(0.25, 0.5, "reverse")
    same_values_fifo_control = fractional_sequence(0.1, 0.2, "fifo")
    bug_sequence = fractional_sequence(0.1, 0.2, "reverse")

    output = {
        "source_root": str(SOURCE_ROOT),
        "nvflare_module": str(nvflare_file),
        "fresh_full_capacity_control": fresh_control,
        "exact_fraction_control": exact_fraction_control,
        "same_values_fifo_control": same_values_fifo_control,
        "bug_sequence": bug_sequence,
    }
    print(json.dumps(output, indent=2, sort_keys=True))

    if not fresh_control["full_request_ok"]:
        raise AssertionError("fresh 1.0 GiB manager rejected a 1.0 GiB request")
    if not exact_fraction_control["full_request_after_free_ok"]:
        raise AssertionError("exact-fraction control unexpectedly rejected the restored 1.0 GiB request")
    if not same_values_fifo_control["full_request_after_free_ok"]:
        raise AssertionError("FIFO free-order control unexpectedly rejected the restored 1.0 GiB request")
    if bug_sequence["full_request_after_free_ok"]:
        raise AssertionError("bug did not reproduce: full request succeeded after reverse fractional frees")
    if not bug_sequence["restored_memory"] < 1.0:
        raise AssertionError("bug did not reproduce: restored memory was not below configured capacity")

    print(
        "BUG_TRIGGERED: after public check/allocate/free of 0.1 GiB and 0.2 GiB on a 1.0 GiB "
        "GPUResourceManager, reverse free order leaves memory "
        f"{bug_sequence['restored_memory_repr']} and rejects a later 1.0 GiB request."
    )


if __name__ == "__main__":
    main()
