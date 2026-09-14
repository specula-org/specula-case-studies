# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
"""Separate caller-metadata evidence; intentionally outside confirmed trace profile."""

import json
import pathlib
import threading
import time

from nvflare.fuel.f3.cellnet import cell as cell_module
from nvflare.fuel.f3.cellnet.cell import Cell
from nvflare.fuel.f3.cellnet.core_cell import CoreCell
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode
from nvflare.fuel.f3.cellnet.utils import make_reply, new_cell_message
from nvflare.fuel.utils.fobs import FOBSContextKey
from nvflare.fuel.utils.network_utils import get_open_ports


def test_real_cell_receiver_metadata(monkeypatch):
    port = get_open_ports(1)[0]
    url = f"tcp://127.0.0.1:{port}"
    cells = [Cell(n, url, secure=False, credentials={}) for n in ("server", "meta-a", "meta-b")]
    channel, topic = "specula_profile", "ordinary_payload"
    delivered = []
    lock = threading.Lock()
    for cell in cells:
        cell.core_cell.start()

    def receive(request):
        with lock:
            delivered.append(request.payload)
        return make_reply(ReturnCode.OK)

    for cell in cells[1:]:
        cell.register_request_cb(channel=channel, topic=topic, cb=receive)
    original = cell_module.encode_payload
    messages = {}
    observations = {}

    def observe_encode(message, *args, **kwargs):
        label = messages.get(id(message))
        if label:
            ctx = kwargs["fobs_ctx"]
            observations[label] = {
                "num_receivers_present": FOBSContextKey.NUM_RECEIVERS in ctx,
                "num_receivers": ctx.get(FOBSContextKey.NUM_RECEIVERS),
                "receiver_ids_present": FOBSContextKey.RECEIVER_IDS in ctx,
                "receiver_ids": ctx.get(FOBSContextKey.RECEIVER_IDS),
            }
        return original(message, *args, **kwargs)

    monkeypatch.setattr(cell_module, "encode_payload", observe_encode)
    try:
        for label, headers in [("broadcast", {}), ("pass_through", {MessageHeaderKey.PASS_THROUGH: True})]:
            message = new_cell_message(headers, b"x")
            messages[id(message)] = label
            replies = cells[0].broadcast_request(
                channel=channel, topic=topic, targets=["meta-a", "meta-b"], request=message, timeout=5
            )
            assert all(r.get_header(MessageHeaderKey.RETURN_CODE) == ReturnCode.OK for r in replies.values())
        message = new_cell_message({}, b"x")
        messages[id(message)] = "fire_and_forget"
        cells[0].fire_and_forget(channel=channel, topic=topic, targets=["meta-a", "meta-b"], message=message)
        deadline = time.monotonic() + 10
        while len(delivered) < 6 and time.monotonic() < deadline:
            time.sleep(0.005)
        assert len(delivered) == 6
        assert observations["broadcast"]["num_receivers"] == 2
        assert observations["broadcast"]["receiver_ids"] == ["meta-a", "meta-b"]
        assert observations["pass_through"]["num_receivers"] == 2
        assert not observations["pass_through"]["receiver_ids_present"]
        assert not observations["fire_and_forget"]["num_receivers_present"]
        assert not observations["fire_and_forget"]["receiver_ids_present"]
        out = pathlib.Path(__file__).resolve().parents[1] / "logs/caller-profiles.json"
        out.write_text(
            json.dumps(
                {
                    "source_sha": "53ba7ee567468ea7971dad4faccef13c6cb35dc2",
                    "evidence": "Actual encode_payload call arguments from real Cell requests; ordinary bytes only, no transfer outcome claim",
                    "observations": observations,
                    "deliveries": len(delivered),
                },
                indent=2,
            )
            + "\n"
        )
    finally:
        for cell in reversed(cells):
            cell.core_cell.stop()
            CoreCell.ALL_CELLS.pop(cell.get_fqcn(), None)
