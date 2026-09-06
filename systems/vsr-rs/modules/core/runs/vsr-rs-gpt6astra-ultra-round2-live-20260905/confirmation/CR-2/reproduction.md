# CR-2 Reproduction

## Test

- Path: `/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/repro/test_bugCR-2_singleton_self_quorum.sh`
- Escalation level: Level 0, pure public API and normal owner-loop operations.
- Command:

```sh
timeout 5m /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/repro/test_bugCR-2_singleton_self_quorum.sh
```

## Output

```text
control_three_replicas: op=1 commit=1 value=7 replies=1
singleton_config: replicas=[0] quorum=1
singleton_request: request_number=0
singleton_round_0: delivered_before_idle=1 delivered_after_idle=1 op=1 commit=0 value=0 replies=0
singleton_round_1: delivered_before_idle=0 delivered_after_idle=1 op=1 commit=0 value=0 replies=0
singleton_round_2: delivered_before_idle=0 delivered_after_idle=1 op=1 commit=0 value=0 replies=0
singleton_round_3: delivered_before_idle=0 delivered_after_idle=1 op=1 commit=0 value=0 replies=0
singleton_round_4: delivered_before_idle=0 delivered_after_idle=1 op=1 commit=0 value=0 replies=0
singleton_round_5: delivered_before_idle=0 delivered_after_idle=1 op=1 commit=0 value=0 replies=0
singleton_round_6: delivered_before_idle=0 delivered_after_idle=1 op=1 commit=0 value=0 replies=0
singleton_round_7: delivered_before_idle=0 delivered_after_idle=1 op=1 commit=0 value=0 replies=0
singleton_final: op=1 commit=0 value=0 replies=0 no_replica_messages_left=true no_replies_left=true
BUG REPRODUCED: singleton accepts quorum=1 and records the request, but no public owner-loop step commits it or returns a reply
```

## Ladder

- Level 0: triggered through `Config::new` + one `add_replica`, `Client::on_request`, `Client::drain`, `Replica::on_message`, repeated `Replica::on_idle` and `Client::on_idle`, and public drain methods. Result: singleton remained at `op=1 commit=0 value=0 replies=0`.
- Level 1: not attempted because Level 0 already triggered the live harm.
- Level 2: not attempted.
- Level 3: not attempted.
