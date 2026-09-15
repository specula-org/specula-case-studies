# 5283: Add Nemotron 3.5 Lightning support to NeMo PEFT example

{'state': 'OPEN', 'createdAt': '2026-09-10T23:22:51Z', 'updatedAt': '2026-09-11T19:54:22Z', 'headRefOid': '593bb8abaed1d08d8b60923fb60771dfe43f7486', 'baseRefOid': '83ec31a8e14bc41f788ec5a739327298173632b5', 'closedAt': None, 'mergedAt': None}

## Body
### Description

The NeMo PEFT example currently defaults to Nemotron 3 Nano and has no supported path for the newer Nemotron 3.5 Lightning model. This change adds an opt-in `--model_profile=lightning35` path for initialization, federated LoRA training, prediction, and evaluation while preserving the existing Nano defaults.

The Lightning profile starts from NVIDIA's published LoRA recipe: BF16 base weights, Transformer Engine attention, PyTorch linear and expert backends, rank 8, alpha 32, zero dropout, `*.out_proj` exclusion, repeated-layer MTP settings, and tensor/context/expert parallel sizes of one. It uses the native NeMo AutoModel factory and checkpointer for adapter initialization, round handoff, and reload.

The example now also:

- validates complete adapter manifests, names, shapes, dtypes, hashes, and finite values before training and exchange;
- records per-round received, loaded, and outgoing hashes, tensor counts, optimizer steps, update norms, and checkpoint locations;
- independently verifies every server aggregate against FP32 weighted averaging;
- prepares deterministic, sentence-disjoint Financial PhraseBank splits and reports reproducible accuracy, Macro-F1, confusion matrices, prediction counts, and response-token loss;
- includes portable H100 validation runners, focused tests, and updated README/notebook instructions for both profiles.

The H100 comparison used the same fixed data split, raw `{sentence} sentiment:` prompt, exact-label scorer, sequence length 512, three clients, three rounds, 300 optimizer steps per client and round, and seeds 42 and 43. LoRA and optimizer settings remained profile-specific.

| Evaluation | Nano 4B | Lightning 30B | Lightning gain |
| --- | ---: | ---: | ---: |
| Base test accuracy | 30.00% | 39.48% | **+9.48 pp** |
| Trained test accuracy, two-seed mean | 73.87% | 83.76% | **+9.90 pp** |
| Trained validation accuracy, two-seed mean | 73.90% | 85.31% | **+11.40 pp** |

Mean trained test Macro-F1 was 71.28% for Nano and 83.47% for Lightning. Both Nano comparison seeds and both Lightning learning seeds completed all nine client tasks; every round handoff and independent aggregate check passed with zero FP32 error.

This validates sequential federated simulation on one H100 NVL. It does not cover separate-host deployment or distributed training within one client.

Resolved model revisions:

- Lightning model and tokenizer: `a9904d24bcc1d289a1950fa9d2b978c47cf903b9`
- Nano model and tokenizer: `dfaf35de3e30f1867dd8dbc38a7fc9fb52d3914f`

### Validation

- `PYTHONDONTWRITEBYTECODE=1 pytest -q tests/unit_test/examples/nemo_peft_adapter_checkpoint_test.py tests/unit_test/examples/nemo_peft_data_split_test.py tests/unit_test/examples/nemo_peft_evaluate_sentiment_test.py tests/unit_test/examples/nemo_peft_job_test.py` — 42 passed
- Three-client, three-round mock federation through exported external processes — passed all nine tasks, adapter handoffs, and independent FP32 aggregates with zero error
- `./runtest.sh -s` — passed Black, isort, flake8, and agent-skill lint
- `bash -n integration/nemo/examples/peft/run_h100_lightning35.sh integration/nemo/examples/peft/run_h100_nano_regression.sh` — passed
- H100 Lightning acceptance campaign — passed
- H100 Nano regression and matched two-seed comparison — passed

### Types of changes

- [x] Non-breaking change (fix or new feature that would not break existing functionality).
- [ ] Breaking change (fix or new feature that would cause existing functionality to change).
- [x] New tests added to cover the changes.
- [ ] Quick tests passed locally by running `./runtest.sh`.
- [x] In-line docstrings updated.
- [x] Documentation updated.


## timeline-comments 5627479707 by codecov-commenter; https://github.com/NVIDIA/NVFlare/pull/5283#issuecomment-5627479707; ; 
## [Codecov](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5283?dropdown=coverage&src=pr&el=h1&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) Report
:white_check_mark: All modified and coverable lines are covered by tests.
:white_check_mark: Project coverage is 66.87%. Comparing base ([`83ec31a`](https://app.codecov.io/gh/NVIDIA/NVFlare/commit/83ec31a8e14bc41f788ec5a739327298173632b5?dropdown=coverage&el=desc&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA)) to head ([`593bb8a`](https://app.codecov.io/gh/NVIDIA/NVFlare/commit/593bb8abaed1d08d8b60923fb60771dfe43f7486?dropdown=coverage&el=desc&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA)).

<details><summary>Additional details and impacted files</summary>



```diff
@@           Coverage Diff           @@
##             main    #5283   +/-   ##
=======================================
  Coverage   66.87%   66.87%           
=======================================
  Files        1021     1021           
  Lines      106100   106100           
=======================================
+ Hits        70951    70952    +1     
+ Misses      35149    35148    -1     
```

| [Flag](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5283/flags?src=pr&el=flags&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) | Coverage Δ | |
|---|---|---|
| [unit-tests](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5283/flags?src=pr&el=flag&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) | `66.87% <ø> (+<0.01%)` | :arrow_up: |

Flags with carried forward coverage won't be shown. [Click here](https://docs.codecov.io/docs/carryforward-flags?utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#carryforward-flags-in-the-pull-request-comment) to find out more.
</details>

[:umbrella: View full report in Codecov by Harness](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5283?dropdown=coverage&src=pr&el=continue&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA).   
:loudspeaker: Have feedback on the report? [Share it here](https://about.codecov.io/codecov-pr-comment-feedback/?utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA).
<details><summary> :rocket: New features to boost your workflow: </summary>

- :snowflake: [Test Analytics](https://docs.codecov.com/docs/test-analytics): Detect flaky tests, report on failures, and find test suite problems.
- :package: [JS Bundle Analysis](https://docs.codecov.com/docs/javascript-bundle-analysis): Save yourself from yourself by tracking and limiting bundle sizes in JS merges.
</details>


## Files
docs/developer_guide.rst
docs/example_applications_algorithms.rst
docs/programming_guide/llm_fine_tuning.rst
integration/nemo/README.md
integration/nemo/examples/README.md
integration/nemo/examples/peft/README.md
integration/nemo/examples/peft/adapter_checkpoint.py
integration/nemo/examples/peft/adapter_persistor.py
integration/nemo/examples/peft/assess_validation.py
integration/nemo/examples/peft/automodel_financial_phrase_dataset.py
integration/nemo/examples/peft/automodel_peft_client.py
integration/nemo/examples/peft/data/split_financial_phrase_data.py
integration/nemo/examples/peft/evaluate_sentiment.py
integration/nemo/examples/peft/federated_automodel_trainer.py
integration/nemo/examples/peft/job.py
integration/nemo/examples/peft/model_profiles.py
integration/nemo/examples/peft/peft.ipynb
integration/nemo/examples/peft/predict_sentiment.py
integration/nemo/examples/peft/prepare_initial_adapter.py
integration/nemo/examples/peft/render_validation_report.py
integration/nemo/examples/peft/run_h100_lightning35.sh
integration/nemo/examples/peft/run_h100_nano_regression.sh
integration/nemo/examples/peft/verify_federated_run.py
tests/unit_test/examples/nemo_peft_adapter_checkpoint_test.py
tests/unit_test/examples/nemo_peft_data_split_test.py
tests/unit_test/examples/nemo_peft_evaluate_sentiment_test.py
tests/unit_test/examples/nemo_peft_job_test.py