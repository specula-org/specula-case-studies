# 5133: Fix portable resource spec regressions

{'state': 'MERGED', 'headRefOid': '7d30767028c147717b460b2e928ed60dff6fcc1c', 'mergeCommit': {'oid': 'ce966f2da5f26748dcc90a0ed38f7441e6127120'}, 'mergedAt': '2026-08-14T20:26:22Z'}

## Body
## What this PR does

- Keeps `num_of_gpus: 0` in non-empty resource-manager requests so zero-GPU jobs with GPU-memory or custom sibling fields remain structurally valid.
- Continues collapsing an otherwise empty zero-GPU/zero-memory request to `{}`.
- Runs legacy nested GPU consistency validation even when `resource_spec` contains `@default`.
- Accepts matching legacy process and launcher GPU counts while continuing to reject genuine mismatches.

## Root cause

Zero GPU counts were removed unconditionally, which could leave a non-empty `GPUResourceManager` request without its required GPU-count key. Separately, the presence of `@default` disabled legacy GPU consistency validation while the generic portable/native conflict check still treated matching legacy declarations as conflicting.

## Validation

- 664 affected scheduler, validator, resource-manager, and Docker/Kubernetes/Slurm launcher tests passed.
- `./runtest.sh -s` passed.
- `git diff --check` passed.

Fixes #5132


## timeline-comments 5296042416 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5133#issuecomment-5296042416; ; 
<h3>Greptile Summary</h3>

The PR repairs zero-GPU resource normalization and legacy GPU consistency validation.
- Removes both GPU admission fields from zero-GPU requests while preserving custom sibling resources and job metadata.
- Makes GPU resource admission defensively accept zero-count requests without reserving GPU memory.
- Validates nested legacy GPU declarations even with `@default`, while permitting matching launcher GPU counts.

<h3>Confidence Score: 5/5</h3>

The PR appears safe to merge.

No blocking failure remains.

<h3>Important Files Changed</h3>




| Filename | Overview |
|----------|----------|
| nvflare/utils/job_launcher_utils.py | Zero-GPU cleanup now preserves custom resources without mutating metadata, and legacy GPU conflict handling consistently validates matching and mismatching declarations. |
| nvflare/app_common/resource_managers/gpu_resource_manager.py | Zero-count checks and reservations safely use the existing empty-reservation lifecycle. |
| tests/unit_test/utils/job_launcher_utils_test.py | Tests cover custom ListResourceManager admission, metadata immutability, zero-GPU normalization, and legacy GPU validation with defaults. |
| tests/unit_test/app_common/resource_managers/gpu_resource_manager_test.py | Tests verify that zero-GPU requirements reserve and allocate nothing for empty and populated GPU managers. |
| tests/unit_test/app_common/job_schedulers/job_scheduler_test.py | Scheduler coverage confirms that a zero-GPU request with nonzero per-GPU memory bypasses GPU admission. |


<!-- greptile_other_comments_section -->

<sub>Reviews (3): Last reviewed commit: ["Merge branch &#39;main&#39; into feat/fix-portab..."](https://github.com/nvidia/nvflare/commit/7d30767028c147717b460b2e928ed60dff6fcc1c) | [Re-trigger Greptile](https://app.greptile.com/api/retrigger?id=53397195)</sub>


## timeline-comments 5296164757 by codecov-commenter; https://github.com/NVIDIA/NVFlare/pull/5133#issuecomment-5296164757; ; 
## [Codecov](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5133?dropdown=coverage&src=pr&el=h1&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) Report
:white_check_mark: All modified and coverable lines are covered by tests.
:white_check_mark: Project coverage is 65.54%. Comparing base ([`cb14940`](https://app.codecov.io/gh/NVIDIA/NVFlare/commit/cb14940f3bd4a2eafd669cdc7c06496b3809509a?dropdown=coverage&el=desc&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA)) to head ([`7d30767`](https://app.codecov.io/gh/NVIDIA/NVFlare/commit/7d30767028c147717b460b2e928ed60dff6fcc1c?dropdown=coverage&el=desc&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA)).
:warning: Report is 1 commits behind head on main.

<details><summary>Additional details and impacted files</summary>



```diff
@@           Coverage Diff           @@
##             main    #5133   +/-   ##
=======================================
  Coverage   65.54%   65.54%           
=======================================
  Files        1012     1012           
  Lines      103151   103159    +8     
=======================================
+ Hits        67613    67620    +7     
- Misses      35538    35539    +1     
```

| [Flag](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5133/flags?src=pr&el=flags&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) | Coverage Δ | |
|---|---|---|
| [unit-tests](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5133/flags?src=pr&el=flag&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) | `65.54% <100.00%> (+<0.01%)` | :arrow_up: |

Flags with carried forward coverage won't be shown. [Click here](https://docs.codecov.io/docs/carryforward-flags?utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#carryforward-flags-in-the-pull-request-comment) to find out more.
</details>

[:umbrella: View full report in Codecov by Harness](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5133?dropdown=coverage&src=pr&el=continue&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA).   
:loudspeaker: Have feedback on the report? [Share it here](https://about.codecov.io/codecov-pr-comment-feedback/?utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA).
<details><summary> :rocket: New features to boost your workflow: </summary>

- :snowflake: [Test Analytics](https://docs.codecov.com/docs/test-analytics): Detect flaky tests, report on failures, and find test suite problems.
- :package: [JS Bundle Analysis](https://docs.codecov.com/docs/javascript-bundle-analysis): Save yourself from yourself by tracking and limiting bundle sizes in JS merges.
</details>


## reviews 4939529958 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5133#pullrequestreview-4939529958; COMMENTED; 



## reviews 4940227199 by pcnudde; https://github.com/NVIDIA/NVFlare/pull/5133#pullrequestreview-4940227199; COMMENTED; 



## reviews 4940736428 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5133#pullrequestreview-4940736428; APPROVED; 



## inline-comments 3785746509 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5133#discussion_r3785746509; ; nvflare/utils/job_launcher_utils.py
<a href="#"><img alt="P1" src="https://greptile-static-assets.s3.amazonaws.com/badges/p1.svg?v=9" align="top"></a> **Zero GPU keys break custom admission**

If a site uses `ListResourceManager` for a custom resource such as `license`, this branch retains zero-valued `num_of_gpus` and `mem_per_gpu_in_GiB` requirements. The manager treats those unconfigured keys as unavailable, causing it to reject a job even when the requested custom resource is available.

**Knowledge Base Used:** [Job Launchers and the `nvflare deploy` CLI](https://app.greptile.com/nvidia-public-github/-/custom-context/knowledge-base/nvidia/nvflare/-/docs/job-launchers-and-deploy-tool.md)


## inline-comments 3786335979 by pcnudde; https://github.com/NVIDIA/NVFlare/pull/5133#discussion_r3786335979; ; nvflare/utils/job_launcher_utils.py
Fixed in 1631b5380. Zero-GPU requests now remove both GPU fields before resource-manager admission while preserving unrelated custom resources. The cleanup covers flat/defaulted and legacy nested process specs without mutating job metadata. I also added defensive zero-count handling in GPUResourceManager plus real ListResourceManager and GPU reservation/allocation lifecycle coverage. The affected 689-test matrix and the full style gate pass.
