# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
"""Python build: compile changed modules and harness, check source import origin."""

import importlib.metadata
import json
import os
import pathlib
import py_compile
import subprocess
import sys

harness = pathlib.Path(__file__).resolve().parents[1]
source = pathlib.Path(os.environ["NVFLARE_SOURCE"])
sys.path.insert(0, str(source))
from nvflare.fuel.f3.streaming import download_service, specula_trace

assert pathlib.Path(download_service.__file__).is_relative_to(source)
assert pathlib.Path(specula_trace.__file__).read_bytes() == (harness / "src/specula_trace.py").read_bytes()
files = [
    source / name
    for name in (
        "nvflare/fuel/f3/streaming/download_service.py",
        "nvflare/fuel/f3/streaming/specula_trace.py",
        "nvflare/client/cell/api.py",
    )
] + list((harness / "src").glob("*.py"))
for i, file in enumerate(files):
    py_compile.compile(str(file), cfile=str(harness / "build" / f"{i}-{file.stem}.pyc"), doraise=True)
versions = {d.metadata["Name"]: d.version for d in importlib.metadata.distributions()}
report = dict(
    python=sys.version,
    executable=sys.executable,
    source=str(source),
    source_sha=subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip(),
    compiled=[str(f) for f in files],
    packages=dict(sorted(versions.items())),
)
(harness / "logs/build.json").write_text(json.dumps(report, indent=2) + "\n")
print(f"Compiled {len(files)} Python modules; confirmed imports from {source}")
