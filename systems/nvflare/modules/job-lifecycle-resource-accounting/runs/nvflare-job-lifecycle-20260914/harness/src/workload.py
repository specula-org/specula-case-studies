# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
# Licensed under the Apache License, Version 2.0.
"""Cooperative supported job payload. No aggregation or GPU computation."""
import time
from nvflare.apis.impl.controller import Controller
from nvflare.apis.executor import Executor
from nvflare.apis.shareable import Shareable
from nvflare.apis.fl_component import FLComponent
from nvflare.apis.event_type import EventType


class HoldController(Controller):
    def __init__(self, seconds=12):
        super().__init__()
        self.seconds = seconds

    def start_controller(self, fl_ctx):
        pass

    def control_flow(self, abort_signal, fl_ctx):
        until = time.monotonic() + self.seconds
        while time.monotonic() < until and not abort_signal.triggered:
            time.sleep(0.1)

    def stop_controller(self, fl_ctx):
        pass


class IdleExecutor(Executor):
    def execute(self, task_name, shareable, fl_ctx, abort_signal):
        return Shareable()


class RaisingAfterLaunch(FLComponent):
    def handle_event(self, event_type, fl_ctx):
        if event_type == EventType.AFTER_JOB_LAUNCH:
            raise OSError('controlled ordinary AFTER_JOB_LAUNCH handler error')
