# 5240: Add NVIDIA FLARE implementation of FedSCS aggregation

{'state': 'OPEN', 'createdAt': '2026-09-01T02:26:30Z', 'updatedAt': '2026-09-13T16:38:02Z', 'headRefOid': 'd5106a4d569a27daf7ac4895be2b9ee9a6cb46b0', 'baseRefOid': '53ba7ee567468ea7971dad4faccef13c6cb35dc2', 'closedAt': None, 'mergedAt': None}

## Body
# FedSCS: Robust Federated Learning via Stable Cosine Similarity

🏆 **Distinguished Conference Paper Award — IEEE ICCST 2025**

This PR adds a NVIDIA FLARE implementation of **Federated Learning with Stable Cosine Similarity (FedSCS)** as a custom `ModelAggregator`.

FedSCS is a robust federated aggregation method that assigns adaptive weights to client updates using **peer-update similarity** and **temporal stability**. It is intended for federated learning settings where client updates may be heterogeneous or potentially unreliable.

## Motivation

In federated learning, participating clients may have heterogeneous or non-IID data, different local training behavior, or potentially unreliable updates. Standard FedAvg primarily weights client updates according to local dataset size and does not explicitly consider whether an update is consistent with the update directions of the other participating clients. As a result, a substantially different or unstable client update can have an undesirable influence on the global model.

FedSCS is designed for these settings by evaluating each client update relative to the aggregate direction of its peers and tracking the client's similarity across communication rounds. Clients whose updates are consistently aligned with their peers receive higher aggregation weights, while updates with lower or less stable similarity receive reduced influence.

Therefore, FedSCS can be useful when a federated learning application has **heterogeneous/non-IID client data or potentially unreliable client updates**, and the aggregation process should account for both **cross-client update agreement and temporal stability** rather than relying solely on client dataset size.

FedSCS does **not** require access to clients' raw training data and should not be interpreted as providing guaranteed malicious-client detection.


## FedSCS Approach

For client \(i\) at federated round \(t\), FedSCS:

1. Computes the peer-consensus update from the other participating clients.
2. Computes the non-negative cosine similarity between the client update and the peer consensus.
3. Maintains a rolling similarity score across communication rounds.
4. Penalizes rapidly changing similarity through a temporal stability term.
5. Normalizes the resulting scores into aggregation weights.
6. Aggregates the client updates using the resulting adaptive weights.

The method requires **O(Nd)** operations for \(N\) participating clients and update dimension \(d\), without constructing a pairwise client-similarity matrix.

## NVIDIA FLARE Integration

FedSCS is implemented as a **custom NVIDIA FLARE `ModelAggregator`** and uses the standard `FedAvgRecipe` for the federated workflow. No custom controller or recipe is required.

```text
FedAvgRecipe
     │
     ├── Client 1 ──┐
     ├── Client 2 ──┤
     ├── Client 3 ──┤
     ├── Client 4 ──┤── DIFF updates
     └── Client 5 ──┘
                    │
             FedSCSAggregator
                    │
          Peer similarity + stability
                    │
             Adaptive weights
                    │
               Global model
```

Client/server model updates are transferred using NVIDIA FLARE's **`TransferType.DIFF`**.

## Example Dataset

The example uses **CIFAR-10 with five simulated clients**. The dataset is prepared locally and is not included in the repository.

The example can be configured to study heterogeneous client updates, including a client with corrupted/noisy training data. A standard CIFAR-10 test set is used for evaluation.

The dataset preparation script:

* downloads CIFAR-10 using a temporary archive;
* verifies the published checksum;
* validates the required CIFAR-10 batch files; and
* only reports successful preparation after validation.

## Project Structure

```text
research/fedscs/
├── README.md
├── requirements.txt
├── job.py
├── client.py
├── prepare_data.sh
└── src/
    ├── fedscs_aggregator.py
    └── model.py
```

## Requirements

* Python 3.9+
* NVIDIA FLARE 2.9.0rc2
* PyTorch
* torchvision
* NumPy

Install the dependencies with:

```bash
pip install -r research/fedscs/requirements.txt
```

## Prepare CIFAR-10

From the NVFlare repository root:

```bash
./research/fedscs/prepare_data.sh
```

## Run the Example

```bash
cd research/fedscs
python job.py
```

The example runs a complete **10-round simulated federated learning experiment** using the standard NVIDIA FLARE Recipe workflow and the custom `FedSCSAggregator`.

## Changes Based on Review

This PR addresses the review feedback by:

* removing the unused duplicate `src/fedscs.py` implementation;
* removing the custom FedSCS controller and recipe;
* implementing FedSCS as a custom `ModelAggregator`;
* using the standard `FedAvgRecipe` with `TransferType.DIFF`;
* increasing the simulation from two to five clients;
* documenting the limitation of two-client peer-consensus;
* hardening CIFAR-10 preparation with temporary download/extraction, checksum verification, and dataset validation;
* removing update clipping to follow the published FedSCS formulation;
* correcting the temporal stability calculation to use the federated round number and the paper's \(s_i^{(0)}=1\) initialization;
* removing unused imports and cleaning formatting and license headers; and
* updating the README with motivation, workflow, integration details, and limitations.

## Validation

The implementation was verified with a complete **10-round NVIDIA FLARE simulation**.

The following repository checks pass:

* Black
* isort
* flake8
* agent-skill-lint
* license checks
* `git diff --check`

## Limitations

FedSCS relies on the assumption that peer consensus provides a useful reference for evaluating client updates.

With only two participating clients, peer-consensus discrimination is degenerate because each client has only one peer. The example therefore uses **five clients**.

The CIFAR-10 experiment is a controlled demonstration and does not represent all forms of non-IID data, adversarial behavior, or client heterogeneity. FedSCS should not be interpreted as guaranteeing malicious-client detection.

## Citation

If you use FedSCS in academic work, please cite:

```text
Rakib Ul Haque and Panagiotis (Panos P.) Markopoulos,
"Robust Federated Learning via Stable Cosine Similarity,"
IEEE ICCST, 2025.
```

## License

This research example follows the licensing terms of the NVIDIA FLARE repository.


## timeline-comments 5487918633 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5240#issuecomment-5487918633; ; 
<!-- greptile_summary -->

<h2><a href="https://app.greptile.com/api/retrigger?id=58887161"><picture><source media="(prefers-color-scheme: dark)" srcset="https://greptile-static-assets.s3.amazonaws.com/badges/RetriggerDark.svg?v=1"><source media="(prefers-color-scheme: light)" srcset="https://greptile-static-assets.s3.amazonaws.com/badges/Retrigger.svg?v=1"><img alt="Retrigger" src="https://greptile-static-assets.s3.amazonaws.com/badges/Retrigger.svg?v=1" align="right"></picture></a>Confidence Score: 3/5</h2>

The PR is not yet safe to merge because unbounded finite client updates can still dominate and corrupt the aggregated global update.

<h3>Summary</h3>

- Adds adaptive peer-similarity and temporal-stability aggregation.
- Adds client training, evaluation, and dataset preparation with explicit validation.
- Documents setup, execution, algorithm assumptions, and limitations.

<sub>Reviews (13) · Last reviewed commit: ["Address FedSCS review feedback"](https://github.com/nvidia/nvflare/commit/d5106a4d569a27daf7ac4895be2b9ee9a6cb46b0)</sub>


## timeline-comments 5532428948 by holgerroth; https://github.com/NVIDIA/NVFlare/pull/5240#issuecomment-5532428948; ; 
Thanks for the contribution. One structural suggestion that would simplify this a lot and also fix the server-side memory profile.

**Suggestion: drop the custom `FedSCS` controller and `FedSCSRecipe`, and implement FedSCS as a custom aggregator only, using DIFF transfer.**

Right now `fedscs_controller.py` copies the whole `FedAvg.run()` loop just to add `aggregator.reset_stats()` + `aggregator.load_model(model)` so the aggregator can subtract the global model. That freezes a copy of FedAvg internals (`_aggr_helper`, `_received_count`, `_maybe_cleanup_memory`, the disk-offload plumbing, ...) which will drift from upstream, and it needs a `FedAvgRecipe` subclass in `job.py` on top.

You don't need the global model on the aggregator side at all. The stock recipe already supports sending deltas:

```python
from nvflare.client.config import TransferType

recipe = FedAvgRecipe(
    ...,
    aggregator=FedSCSAggregator(...),
    params_transfer_type=TransferType.DIFF,
)
```

With that, the Client API computes `delta_i = w_i - w_global` on the client and `accept_model()` receives the delta directly. The aggregator then clips, scores cosine similarity against the peer sum, and returns the weighted delta:

```python
return FLModel(params=aggregated_delta, params_type=ParamsType.DIFF, metrics=...)
```

`FedAvg.update_model()` -> `FLModelUtils.update_model()` adds a DIFF result onto the server's global model, which is exactly `w_global + sum_i(alpha_i * clipped_delta_i)` from your docstring. Stock `FedAvg` + stock `FedAvgRecipe`, no controller, no recipe subclass. This is also the pattern used by the other custom-aggregator examples (`examples/advanced/cifar10/pt/cifar10-sim/cifar10_custom_aggr`, `examples/advanced/medgemma`).

**Memory.** This matters beyond tidiness. The current aggregator keeps a float64 copy of the global model (`load_model`), a float64 copy of every client model (`client_models`), and a second float64 copy of every delta (`client_updates`), and rebuilds the N-1 peer sum from scratch for each client. For float32 weights that is roughly 4N+2 model-sizes at peak, and the `np.asarray` calls also materialize any tensor-disk-offload refs FedAvg passes through. FedSCS inherently needs all N deltas before it can weight anything, so O(N) is the floor, but it can be close to that floor: store each incoming delta once (flattened, original dtype, clipped on arrival), keep one running total, and compute the peer sum for client i as `total - delta_i`. That gets you to about N+1 flattened models with no extra copy of the global model.

Happy to look at a revised version. If it helps, I can sketch the accept/aggregate skeleton for the DIFF-based aggregator.



## timeline-comments 5587190239 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5240#issuecomment-5587190239; ; 
Want your agent to iterate on Greptile's feedback? Try [*greploops*](https://github.com/greptileai/skills/blob/main/greploop/SKILL.md).


## timeline-comments 5653411354 by Rakib-Ul-Haque; https://github.com/NVIDIA/NVFlare/pull/5240#issuecomment-5653411354; ; 
Thanks for the detailed review. I’ve addressed the requested changes:

* Removed the unused duplicate `src/fedscs.py` implementation.
* Removed the custom FedSCS controller/recipe and implemented FedSCS as a custom `ModelAggregator` using the standard `FedAvgRecipe`.
* Switched the example to `TransferType.DIFF`.
* Increased the simulation to five clients and documented the two-client limitation.
* Hardened CIFAR-10 preparation with temporary download/extraction, checksum verification, and dataset validation.
* Updated the README with the motivation, workflow, integration details, and limitations of FedSCS.
* Removed update clipping and corrected the temporal stability calculation to follow the published FedSCS formulation.
* Added the required license headers and cleaned up formatting and unused imports.
* Verified the example with a complete 10-round NVIDIA FLARE simulation.
* Confirmed that the targeted repository checks pass, including Black, isort, flake8, agent-skill-lint, license checks, and `git diff --check`.

The changes have been pushed to the `fedscs` branch. Thanks again for the helpful feedback!



## reviews 5073407799 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5240#pullrequestreview-5073407799; COMMENTED; 



## reviews 5078892336 by ZiyueXu77; https://github.com/NVIDIA/NVFlare/pull/5240#pullrequestreview-5078892336; COMMENTED; 



## reviews 5083327156 by Rakib-Ul-Haque; https://github.com/NVIDIA/NVFlare/pull/5240#pullrequestreview-5083327156; COMMENTED; 



## reviews 5096428396 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5240#pullrequestreview-5096428396; COMMENTED; 



## reviews 5096533293 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5240#pullrequestreview-5096533293; COMMENTED; 



## reviews 5103150811 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5240#pullrequestreview-5103150811; COMMENTED; 



## reviews 5103569971 by ZiyueXu77; https://github.com/NVIDIA/NVFlare/pull/5240#pullrequestreview-5103569971; COMMENTED; 
thanks for the PR! Some comments


## reviews 5105029829 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5240#pullrequestreview-5105029829; COMMENTED; 

FedSCS: Robust Federated Learning via Stable Cosine Similarity
FedSCS is a robust federated aggregation method that uses client update similarity and temporal stability scores to compute adaptive aggregation weights.


Please add some background information, the title only describe the name and what it does, but did not explain why do we need this ? in what cases, we should use this algorithm ? what kind of the problem it is trying to solve. 




## reviews 5106895885 by holgerroth; https://github.com/NVIDIA/NVFlare/pull/5240#pullrequestreview-5106895885; COMMENTED; 
Low-effort single-pass review; three inline notes below.


## reviews 5190772587 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5240#pullrequestreview-5190772587; COMMENTED; 



## inline-comments 3900236821 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5240#discussion_r3900236821; ; research/fedscs/src/fedscs_aggregator.py
<a href="#"><img alt="P1" src="https://greptile-static-assets.s3.amazonaws.com/badges/p1.svg?v=9" align="top"></a> <a href="#"><img alt="security" src="https://greptile-static-assets.s3.amazonaws.com/badges/Security.svg?v=2" align="top"></a> **Non-finite models poison aggregation**

When a faulty or malicious client returns NaN or infinite parameters, `accept_model` stores them and the weighted sum propagates them into the full global model, corrupting subsequent training, evaluation, and persistence.

**How this was verified:** The FedAvg callback and `FLModel` validation pass nonempty parameters without finiteness checks, and `_aggregate_models` directly multiplies and sums the stored arrays.

```suggestion
        client_model = self._flatten_model(
            model.params
        )

        if any(
            not np.isfinite(value).all()
            for value in client_model.values()
        ):
            raise ValueError(
                f"Non-finite parameters from {client_name}"
            )

        self.client_models[client_name] = client_model
```


## inline-comments 3900236910 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5240#discussion_r3900236910; ; research/fedscs/train.py
<a href="#"><img alt="P1" src="https://greptile-static-assets.s3.amazonaws.com/badges/p1.svg?v=9" align="top"></a> **Empty loader reports zero loss**

When dataset preparation produces an empty training loader, this fallback reports a zero loss and allows an untrained model to be sent instead of raising a descriptive data-preparation error.

```suggestion
        if not len(train_loader):
            raise ValueError("Training data loader is empty")

        avg_loss = running_loss / len(train_loader)
```

**Rule Used:** When data_loader might be empty during loss comput... ([source](https://app.greptile.com/nvidia-public-github/github/NVIDIA/nvflare/-/custom-context?memory=783565ac-d530-4d49-a8bc-55877cb0a0cd))

**Learned From**
[NVIDIA/NVFlare#4001](https://github.com/NVIDIA/NVFlare/pull/4001#discussion_r2714180688)


## inline-comments 3904803027 by ZiyueXu77; https://github.com/NVIDIA/NVFlare/pull/5240#discussion_r3904803027; ; research/fedscs/data/cifar-10-batches-py/batches.meta
Please replace data files with a "prepare_data.sh" script for this step. Example here "https://github.com/NVIDIA/NVFlare/blob/main/examples/advanced/cifar10/pt/cifar10-sim/prepare_data.sh"


## inline-comments 3908644513 by Rakib-Ul-Haque; https://github.com/NVIDIA/NVFlare/pull/5240#discussion_r3908644513; ; research/fedscs/data/cifar-10-batches-py/batches.meta
Dear @ZiyueXu77 

Thank you for your valuable comments. The file is updated accordingly.


## inline-comments 3919787780 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5240#discussion_r3919787780; ; research/fedscs/src/fedscs_aggregator.py
<a href="#"><img alt="P1" src="https://greptile-static-assets.s3.amazonaws.com/badges/p1.svg?v=9" align="top"></a> <a href="#"><img alt="security" src="https://greptile-static-assets.s3.amazonaws.com/badges/Security.svg?v=2" align="top"></a> **Finite updates poison aggregation**

When a faulty or malicious client submits a finite model whose update is an arbitrarily large positive multiple of an honest update, the finiteness check accepts it and scale-invariant cosine scoring assigns it a normal weight. Applying that weight to the unbounded full model lets the client dominate the next global model, corrupting subsequent training, evaluation, and persistence.

**How this was verified:** The acceptance path imposes no magnitude bound, cosine similarity ignores positive scaling, and `_aggregate_models` directly sums the weighted full model values.


## inline-comments 3919787786 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5240#discussion_r3919787786; ; research/fedscs/src/fedscs_aggregator.py
<a href="#"><img alt="P1" src="https://greptile-static-assets.s3.amazonaws.com/badges/p1.svg?v=9" align="top"></a> <a href="#"><img alt="security" src="https://greptile-static-assets.s3.amazonaws.com/badges/Security.svg?v=2" align="top"></a> **Incomplete models corrupt aggregation**

When a faulty or malicious client submits a nonempty, finite subset of the global parameters, `accept_model` stores it without validating the complete key set. If that contribution arrives first, its omissions disappear from the returned FULL model; otherwise, omitted parameters are summed using weights that still include that client, silently scaling those parameters down.

**How this was verified:** The FedAvg callback and `accept_model` permit partial mappings, while `_aggregate_models` takes keys from the first client and skips missing contributors without renormalizing.


## inline-comments 3919887626 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5240#discussion_r3919887626; ; research/fedscs/src/fedscs_aggregator.py
<a href="#"><img alt="P1" src="https://greptile-static-assets.s3.amazonaws.com/badges/p1.svg?v=9" align="top"></a> <a href="#"><img alt="security" src="https://greptile-static-assets.s3.amazonaws.com/badges/Security.svg?v=2" align="top"></a> **Clipping does not bound aggregation**

When a client submits a finite update larger than `max_update_norm` that aligns with the peer updates, clipping preserves its direction and it retains a nonzero similarity-derived weight, but `_aggregate_models` applies that weight to the original unbounded values in `self.client_models`. The oversized model can therefore still dominate and corrupt the next global model. **How this was verified:** The clipped values are stored only in `self.client_updates` for scoring, while the weighted sum reads the original `self.client_models` values.


## inline-comments 3925535722 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5240#discussion_r3925535722; ; research/fedscs/train.py
<a href="#"><img alt="P1" src="https://greptile-static-assets.s3.amazonaws.com/badges/p1.svg?v=9" align="top"></a> **Empty evaluation reports valid accuracy**

When `test_loader` is empty, `evaluate()` divides by a synthetic denominator and returns `0.0`, which the client sends as a valid accuracy metric. This masks a data-preparation failure and can affect model selection or stopping decisions.

```suggestion
    if total == 0:
        raise ValueError("Test data loader is empty")

    accuracy = 100.0 * correct / total
```


## inline-comments 3925882225 by ZiyueXu77; https://github.com/NVIDIA/NVFlare/pull/5240#discussion_r3925882225; ; research/fedscs/src/fedscs.py
Is this module intended to be used? A repository-wide search found no imports of `flatten_update`, `compute_fedscs_weights`, or `aggregate_models`; `FedSCSAggregator` independently reimplements these operations, and its temporal-score behavior differs from this module. Please either have the aggregator reuse this framework-independent implementation (with focused tests), or remove this file so there is one authoritative implementation of the algorithm.


## inline-comments 3925882234 by ZiyueXu77; https://github.com/NVIDIA/NVFlare/pull/5240#discussion_r3925882234; ; research/fedscs/job.py
Could we note the two-client limitation in the README, or use at least three clients if this example is meant to demonstrate robust discrimination? With exactly two participants, each client's peer sum is just the other update, so cosine symmetry gives both clients the same raw score and, from equal history, 0.5 weights. Two clients are sufficient as an integration smoke test, but they cannot demonstrate identification of an outlier from this signal alone.


## inline-comments 3925882242 by ZiyueXu77; https://github.com/NVIDIA/NVFlare/pull/5240#discussion_r3925882242; ; research/fedscs/prepare_data.sh
This existence check can accept an incomplete or corrupt preparation. I interrupted the download locally; extraction left a partial dataset directory. After resuming the archive, this branch printed `CIFAR-10 dataset already prepared`, while `train.py` failed with `Dataset not found or corrupted`. Please download to a temporary file with `curl --fail`, verify the published checksum, extract into a temporary directory, and only return success after validating the required batch files.


## inline-comments 3925882250 by ZiyueXu77; https://github.com/NVIDIA/NVFlare/pull/5240#discussion_r3925882250; ; research/fedscs/job.py
The required repository checks currently fail for this example. The license checker rejects all seven new Python files; Black would reformat six files; isort rejects five; and flake8 reports unused imports here and in `fedscs.py`/`fedscs_aggregator.py`. `git diff --check` also flags the extra blank line at the end of the README. Please run the repository formatting/import cleanup and add the canonical license headers before merge.


## inline-comments 3928778681 by holgerroth; https://github.com/NVIDIA/NVFlare/pull/5240#discussion_r3928778681; ; research/fedscs/src/fedscs.py
This module appears unused: `job.py`, `fedscs_controller.py` and `fedscs_aggregator.py` never import it, and the aggregator re-implements the flatten/cosine/weight logic. The two also disagree on the algorithm: `compute_fedscs_weights` uses a running average divided by `len(previous_scores) + 1` (number of clients, not rounds), while the aggregator uses `stability = 1 - |cur - prev| / max(...)`. Since the README points readers here as the algorithm, I would either drop this file or have the aggregator import from it so there is one definition.


## inline-comments 3928778686 by holgerroth; https://github.com/NVIDIA/NVFlare/pull/5240#discussion_r3928778686; ; research/fedscs/client.py
Missing the Apache-2.0 license header. Same for `job.py`, `train.py`, `src/fedscs.py`, `src/model.py` and `src/fedscs_controller.py`. The repo license check (`./runtest.sh -l`) covers `research/`, so CI will fail on these.


## inline-comments 3928778690 by holgerroth; https://github.com/NVIDIA/NVFlare/pull/5240#discussion_r3928778690; ; research/fedscs/src/fedscs_aggregator.py
`List`, `Tuple` and `Shareable` are imported but never used (flake8 F401).


## inline-comments 3999697689 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5240#discussion_r3999697689; ; research/fedscs/src/fedscs_aggregator.py
<a href="#"><img alt="P1" src="https://greptile-static-assets.s3.amazonaws.com/badges/p1.svg?v=9" align="top"></a> <a href="#"><img alt="security" src="https://greptile-static-assets.s3.amazonaws.com/badges/Security.svg?v=2" align="top"></a> **Finite updates overflow aggregation**

When clients submit individually finite DIFF values large enough to overflow float64 arithmetic, the unchecked sums and cosine calculations produce infinite or NaN weights or aggregate values. FedAvg then adds the non-finite DIFF to the global parameters, corrupting the model that is persisted and distributed.

**How this was verified:** Per-input validation permits arbitrary finite magnitudes, the aggregate arithmetic has no output finiteness check, and FedAvg directly adds the returned DIFF to the global model.


## inline-comments 3999697693 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5240#discussion_r3999697693; ; research/fedscs/client.py
<a href="#"><img alt="P1" src="https://greptile-static-assets.s3.amazonaws.com/badges/p1.svg?v=9" align="top"></a> **Empty loaders report valid metrics**

When a client receives an empty training or test dataset, `evaluate` and `train_one_round` return zero-valued metrics instead of raising a data-preparation error. The client then sends an untrained update with zero loss and accuracy represented as valid results, masking the invalid dataset.

**Rule Used:** When data_loader might be empty during loss computation, prefer raising an explicit error rather than handling division by zero silently. Use ValueError with descriptive message to help identify data preparation issues early. ([source](https://app.greptile.com/nvidia-public-github/github/NVIDIA/nvflare/-/custom-context?memory=783565ac-d530-4d49-a8bc-55877cb0a0cd))

**Learned From**
[NVIDIA/NVFlare#4001](https://github.com/NVIDIA/NVFlare/pull/4001#discussion_r2714180688)


## Files
research/fedscs/README.md
research/fedscs/client.py
research/fedscs/job.py
research/fedscs/prepare_data.sh
research/fedscs/requirements.txt
research/fedscs/src/fedscs_aggregator.py
research/fedscs/src/model.py