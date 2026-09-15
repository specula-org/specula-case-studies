# 5266: Bump transformers from 4.57.1 to 5.10.1 in /research/fedcore

{'state': 'OPEN', 'createdAt': '2026-09-04T13:51:32Z', 'updatedAt': '2026-09-04T14:05:18Z', 'headRefOid': '01c9f0b1decde897a396911c342ba2ad578d55d4', 'baseRefOid': 'c277b4ed94c03cc0bc4671798cf4b35ded9085cb', 'closedAt': None, 'mergedAt': None}

## Body
Bumps [transformers](https://github.com/huggingface/transformers) from 4.57.1 to 5.10.1.
<details>
<summary>Release notes</summary>
<p><em>Sourced from <a href="https://github.com/huggingface/transformers/releases">transformers's releases</a>.</em></p>
<blockquote>
<h1>Release v5.10.1</h1>
<p>v5.10.0 was yanked as we publish on a corrupted branch. Sorry everyone, this happens when we rush a release!!!</p>
<h2>New Model additions</h2>
<h3>Gemma4 unified+ Gemma4 MTP</h3>
<!-- raw HTML omitted -->
<p>Gemma 4 12B Unified is an <strong>encoder-free</strong> multimodal model with pretrained and instruction-tuned variants. Unlike <a href="https://github.com/huggingface/transformers/blob/HEAD/gemma4">standard Gemma 4</a>, which uses dedicated encoder towers, Gemma 4 12B Unified projects raw inputs directly into the language model's embedding space through lightweight linear pipelines. This results in a simpler architecture while maintaining strong multimodal performance.</p>
<p>Key differences from standard Gemma 4:</p>
<ul>
<li><strong>No Vision Tower</strong>: Raw pixel patches are projected directly into LM space via a <code>Dense + LayerNorm</code> pipeline with factorized 2D positional embeddings, replacing the vision encoder.</li>
<li><strong>No Audio Tower</strong>: Raw 16 kHz waveform samples are chunked into fixed-length frames and projected through a simple <code>RMSNorm → Linear</code> pipeline, replacing the mel spectrogram + Conformer encoder.</li>
<li><strong>Shared Multimodal Pipeline</strong>: Both vision and audio use the same <code>Gemma4UnifiedMultimodalEmbedder</code> (RMSNorm → Linear) for the final projection to text hidden space.</li>
</ul>
<p>You can find the original Gemma 4 12B Unified checkpoints under the <a href="https://huggingface.co/collections/google/gemma-4">Gemma 4</a> release.</p>
<ul>
<li>who needs encoders? (<a href="https://redirect.github.com/huggingface/transformers/issues/46385">#46385</a>) by <a href="https://github.com/douglas-reid"><code>@​douglas-reid</code></a> <a href="https://github.com/sgerrard"><code>@​sgerrard</code></a> <a href="https://github.com/vasqu"><code>@​vasqu</code></a> <a href="https://github.com/molbap"><code>@​molbap</code></a></li>
</ul>
<h3>Sapiens2</h3>
<p>Sapiens2 is a family of high-resolution vision transformers pretrained on ~1 billion curated human images, designed for human-centric computer vision tasks including pose estimation, body-part segmentation, surface normal estimation, and pointmap estimation. The models scale from 0.4B to 5B parameters and train at native 1K resolution, with hierarchical 4K variants for extended spatial reasoning. Sapiens2 achieves substantial improvements over its predecessor with +4 mAP in pose estimation, +24.3 mIoU in body-part segmentation, and 45.6% error reduction in normal estimation.</p>
<p><strong>Links:</strong> <a href="https://huggingface.co/docs/transformers/main/en/model_doc/sapiens2">Documentation</a> | <a href="https://huggingface.co/papers/2604.21681">Paper</a></p>
<ul>
<li>Add Sapiens2 Model (<a href="https://redirect.github.com/huggingface/transformers/issues/45919">#45919</a>) by <a href="https://github.com/guarin"><code>@​guarin</code></a> in <a href="https://redirect.github.com/huggingface/transformers/pull/45919">#45919</a></li>
</ul>
<h3>DeepSeek-OCR-2</h3>
<p>DeepSeek-OCR-2 is an OCR-specialized vision-language model built on a distinctive architecture that combines a SAM ViT-B vision encoder with a Qwen2 hybrid attention encoder, connected through an MLP projector to a DeepSeek-V2 Mixture-of-Experts (MoE) language model. The model features a hybrid attention mechanism that applies bidirectional attention over image tokens and causal attention over query tokens, enabling efficient and accurate document understanding. It supports both plain OCR tasks and grounding capabilities with coordinate-aware output for document conversion to markdown format.</p>
<p><strong>Links:</strong> <a href="https://huggingface.co/docs/transformers/main/en/model_doc/deepseek_ocr2">Documentation</a></p>
<ul>
<li>Add Deepseek-OCR-2 model (<a href="https://redirect.github.com/huggingface/transformers/issues/45075">#45075</a>) by <a href="https://github.com/thisisiron"><code>@​thisisiron</code></a> in <a href="https://redirect.github.com/huggingface/transformers/pull/45075">#45075</a></li>
</ul>
<h3>Mellum</h3>
<p>Mellum is a code-focused Mixture-of-Experts language model developed by JetBrains. It is derived from the Qwen3-MoE architecture with per-layer-type RoPE and interleaved sliding window attention. The model has 12B total parameters with 2.5B active parameters per token, using 64 routed experts with 8 activated per token across 28 layers.</p>
<p><strong>Links:</strong> <a href="https://huggingface.co/docs/transformers/main/en/model_doc/mellum">Documentation</a></p>
<ul>
<li>feat: Add support for JetBrains' <code>Mellum</code> v2 code generation model (<a href="https://redirect.github.com/huggingface/transformers/issues/46112">#46112</a>) by <a href="https://github.com/shadeMe"><code>@​shadeMe</code></a> in <a href="https://redirect.github.com/huggingface/transformers/pull/46112">#46112</a></li>
</ul>
<h2>Breaking changes</h2>
<p>The Gemma4 vision pooler now casts inputs to float32 before scaling to prevent float16 overflow (inf saturation) with large checkpoints, which may cause minor numerical differences in outputs for users running Gemma-4 vision models in float16.</p>
<ul>
<li>🚨 Fix float16 overflow in Gemma4 vision pooler (<a href="https://redirect.github.com/huggingface/transformers/issues/46277">#46277</a>) by <a href="https://github.com/Bluear7878"><code>@​Bluear7878</code></a></li>
</ul>
<p>Audio Language Models (ALMs) now have a dedicated base model class without a language modeling head, aligning them with the design of Vision Language Models (VLMs); users relying on the previous model class structure should update their code to use the new base model class where appropriate.</p>
<ul>
<li>🚨 [ALM] Add base model without head (<a href="https://redirect.github.com/huggingface/transformers/issues/45534">#45534</a>) by <a href="https://github.com/eustlb"><code>@​eustlb</code></a></li>
</ul>
<!-- raw HTML omitted -->
</blockquote>
<p>... (truncated)</p>
</details>
<details>
<summary>Commits</summary>
<ul>
<li><a href="https://github.com/huggingface/transformers/commit/90c3ae54d448d4906b6167317ea5a7f5d48a232d"><code>90c3ae5</code></a> Patch because we had to yank 5.10 because the release branch was not up to date</li>
<li><a href="https://github.com/huggingface/transformers/commit/0bd94b37db639d8f29a094dce2fde06f86af8968"><code>0bd94b3</code></a> v5.10.0</li>
<li><a href="https://github.com/huggingface/transformers/commit/1423d22f7a3b62e8c70ad67b58ec25cd9b675897"><code>1423d22</code></a> who needs encoders? (<a href="https://redirect.github.com/huggingface/transformers/issues/46385">#46385</a>)</li>
<li><a href="https://github.com/huggingface/transformers/commit/50eb20a24f9dd512e6770072f422e4b86ca3cd98"><code>50eb20a</code></a> Fix dsv4 dequant + tp/ep (<a href="https://redirect.github.com/huggingface/transformers/issues/46378">#46378</a>)</li>
<li><a href="https://github.com/huggingface/transformers/commit/74464e8c49c91b574c30cc3cb3c5a44000237299"><code>74464e8</code></a> Fix wrong changes produced by style/repo. check bot (<a href="https://redirect.github.com/huggingface/transformers/issues/46371">#46371</a>)</li>
<li><a href="https://github.com/huggingface/transformers/commit/1b8ec344fb6c277235fc76c37e7a5c156a1f0ddc"><code>1b8ec34</code></a> Fix path traversal when saving Bark voice preset embeddings (<a href="https://redirect.github.com/huggingface/transformers/issues/46237">#46237</a>)</li>
<li><a href="https://github.com/huggingface/transformers/commit/e820678256f22e7647e39e8b7ed040fa81b7b872"><code>e820678</code></a> Add Sapiens2 Model (<a href="https://redirect.github.com/huggingface/transformers/issues/45919">#45919</a>)</li>
<li><a href="https://github.com/huggingface/transformers/commit/595721c44cb14db37fa504903e2edd5e9f0eba43"><code>595721c</code></a> Pass library_name/version to Hub calls via a shared HfApi (<a href="https://redirect.github.com/huggingface/transformers/issues/46318">#46318</a>)</li>
<li><a href="https://github.com/huggingface/transformers/commit/0f0036c888ed81b714cb04aa6fe6689eb36bce0a"><code>0f0036c</code></a> docs: update ACL Anthology URL in CITATION.cff (<a href="https://redirect.github.com/huggingface/transformers/issues/46352">#46352</a>)</li>
<li><a href="https://github.com/huggingface/transformers/commit/fa6c8308e22dade298c10c72d44937e41b962353"><code>fa6c830</code></a> DeepGEMM BF16 + mixed FP8/FP4 + MegaMoE + refactor (<a href="https://redirect.github.com/huggingface/transformers/issues/45634">#45634</a>)</li>
<li>Additional commits viewable in <a href="https://github.com/huggingface/transformers/compare/v4.57.1...v5.10.1">compare view</a></li>
</ul>
</details>
<br />


[![Dependabot compatibility score](https://dependabot-badges.githubapp.com/badges/compatibility_score?dependency-name=transformers&package-manager=pip&previous-version=4.57.1&new-version=5.10.1)](https://docs.github.com/en/github/managing-security-vulnerabilities/about-dependabot-security-updates#about-compatibility-scores)

Dependabot will resolve any conflicts with this PR as long as you don't alter it yourself. You can also trigger a rebase manually by commenting `@dependabot rebase`.

[//]: # (dependabot-automerge-start)
[//]: # (dependabot-automerge-end)

---

<details>
<summary>Dependabot commands and options</summary>
<br />

You can trigger Dependabot actions by commenting on this PR:
- `@dependabot rebase` will rebase this PR
- `@dependabot recreate` will recreate this PR, overwriting any edits that have been made to it
- `@dependabot show <dependency name> ignore conditions` will show all of the ignore conditions of the specified dependency
- `@dependabot ignore this major version` will close this PR and stop Dependabot creating any more for this major version (unless you reopen the PR or upgrade to it yourself)
- `@dependabot ignore this minor version` will close this PR and stop Dependabot creating any more for this minor version (unless you reopen the PR or upgrade to it yourself)
- `@dependabot ignore this dependency` will close this PR and stop Dependabot creating any more for this dependency (unless you reopen the PR or upgrade to it yourself)
You can disable automated security fix PRs for this repo from the [Security Alerts page](https://github.com/NVIDIA/NVFlare/network/alerts).

</details>

## timeline-comments 5541588119 by codecov-commenter; https://github.com/NVIDIA/NVFlare/pull/5266#issuecomment-5541588119; ; 
## [Codecov](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5266?dropdown=coverage&src=pr&el=h1&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) Report
:white_check_mark: All modified and coverable lines are covered by tests.
:white_check_mark: Project coverage is 66.56%. Comparing base ([`c277b4e`](https://app.codecov.io/gh/NVIDIA/NVFlare/commit/c277b4ed94c03cc0bc4671798cf4b35ded9085cb?dropdown=coverage&el=desc&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA)) to head ([`01c9f0b`](https://app.codecov.io/gh/NVIDIA/NVFlare/commit/01c9f0b1decde897a396911c342ba2ad578d55d4?dropdown=coverage&el=desc&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA)).

<details><summary>Additional details and impacted files</summary>



```diff
@@            Coverage Diff             @@
##             main    #5266      +/-   ##
==========================================
+ Coverage   66.55%   66.56%   +0.01%     
==========================================
  Files        1018     1018              
  Lines      105278   105278              
==========================================
+ Hits        70067    70081      +14     
+ Misses      35211    35197      -14     
```

| [Flag](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5266/flags?src=pr&el=flags&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) | Coverage Δ | |
|---|---|---|
| [unit-tests](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5266/flags?src=pr&el=flag&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) | `66.56% <ø> (+0.01%)` | :arrow_up: |

Flags with carried forward coverage won't be shown. [Click here](https://docs.codecov.io/docs/carryforward-flags?utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#carryforward-flags-in-the-pull-request-comment) to find out more.
</details>

[:umbrella: View full report in Codecov by Harness](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5266?dropdown=coverage&src=pr&el=continue&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA).   
:loudspeaker: Have feedback on the report? [Share it here](https://about.codecov.io/codecov-pr-comment-feedback/?utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA).
<details><summary> :rocket: New features to boost your workflow: </summary>

- :snowflake: [Test Analytics](https://docs.codecov.com/docs/test-analytics): Detect flaky tests, report on failures, and find test suite problems.
- :package: [JS Bundle Analysis](https://docs.codecov.com/docs/javascript-bundle-analysis): Save yourself from yourself by tracking and limiting bundle sizes in JS merges.
</details>


## Files
examples/advanced/qwen3-vl/requirements.txt
research/fedcore/requirements.txt