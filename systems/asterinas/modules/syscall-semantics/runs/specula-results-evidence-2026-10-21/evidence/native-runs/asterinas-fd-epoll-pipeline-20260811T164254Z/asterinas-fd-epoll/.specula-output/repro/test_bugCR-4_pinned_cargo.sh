#!/usr/bin/env bash
set -euo pipefail

source_root=/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-4/worktree
base_crate=/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-4_thread_registration.target/osdk/asterinas-run-base

# cargo-osdk creates its temporary base crate outside the worktree, where
# rustup cannot discover the worktree's rust-toolchain.toml. Keep that build
# on the source-declared toolchain and start its lock from the source lock.
if [[ "$PWD" == "$base_crate" ]]; then
    cp "$source_root/Cargo.lock" Cargo.lock
fi

exec /home/chin39/.nix-profile/bin/cargo +nightly-2026-07-21 "$@"
