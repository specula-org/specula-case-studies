# Copyright (c) 2026, NVIDIA CORPORATION.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Pytest plugin: assert source origin and optionally install behavior-free hooks."""
import os
import sys
from pathlib import Path


def pytest_sessionstart(session):
    import nvflare

    expected = Path(os.environ['EXPECT_NVFLARE_ROOT']).resolve()
    assert Path(nvflare.__file__).resolve().is_relative_to(expected), nvflare.__file__
    if os.environ.get('NVF_HOOK_CONTROL') == 'noop':
        from nvflare.fuel.utils import tla_hooks

        class NoopTracer:
            def section(self, *args, **kwargs):
                return tla_hooks._NULL

            context = section

            def in_context(self, tag):
                return False

            def take(self, key, default=None):
                return default

            def __getattr__(self, name):
                if name in {'begin', 'end', 'end_open', 'cancel', 'emit', 'event', 'rename',
                            'set_fields', 'gate', 'note'}:
                    return lambda *args, **kwargs: None
                raise AttributeError(name)

        tla_hooks.install(NoopTracer())


def pytest_sessionfinish(session, exitstatus):
    expected = Path(os.environ['EXPECT_NVFLARE_ROOT']).resolve()
    wrong = {name: module.__file__ for name, module in list(sys.modules.items())
             if name.startswith('nvflare') and getattr(module, '__file__', None)
             and not Path(module.__file__).resolve().is_relative_to(expected)}
    assert not wrong, wrong
