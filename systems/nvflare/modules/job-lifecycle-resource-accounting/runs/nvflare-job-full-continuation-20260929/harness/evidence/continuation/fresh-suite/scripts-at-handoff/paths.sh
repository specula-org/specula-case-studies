#!/bin/bash
# Pinned continuation paths; callers may relocate the same pinned source/runtime.
NVF_CONTINUATION_ROOT="${NVF_CONTINUATION_ROOT:-/home/ubuntu/specula-nvflare-gpt-continuation-20260926}"
export NVF_SOURCE="${NVF_SOURCE:-$NVF_CONTINUATION_ROOT/source}"
export NVF_PYTHON="${NVF_PYTHON:-$NVF_CONTINUATION_ROOT/nvflare-venv/bin/python}"
export SPECULA_ROOT="${SPECULA_ROOT:-$NVF_CONTINUATION_ROOT/framework}"
export PYTHONDONTWRITEBYTECODE=1
export SPECULA_TLC_MEMORY_LIMIT=64G
export SPECULA_TLC_WORKER_LIMIT=16
