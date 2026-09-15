# 5267: Bump torch from 2.6.0 to 2.13.0 in /research/fedcore

{'state': 'OPEN', 'createdAt': '2026-09-04T13:51:39Z', 'updatedAt': '2026-09-04T14:06:31Z', 'headRefOid': 'ce30be0ada3c6b8e93f4740d763fb4e82128880d', 'baseRefOid': 'c277b4ed94c03cc0bc4671798cf4b35ded9085cb', 'closedAt': None, 'mergedAt': None}

## Body
Bumps [torch](https://github.com/pytorch/pytorch) from 2.6.0 to 2.13.0.
<details>
<summary>Release notes</summary>
<p><em>Sourced from <a href="https://github.com/pytorch/pytorch/releases">torch's releases</a>.</em></p>
<blockquote>
<h1>PyTorch 2.13.0 Release Notes</h1>
<ul>
<li><a href="https://github.com/pytorch/pytorch/blob/HEAD/#highlights">Highlights</a></li>
<li><a href="https://github.com/pytorch/pytorch/blob/HEAD/#backwards-incompatible-changes">Backwards Incompatible Changes</a></li>
<li><a href="https://github.com/pytorch/pytorch/blob/HEAD/#deprecations">Deprecations</a></li>
<li><a href="https://github.com/pytorch/pytorch/blob/HEAD/#new-features">New Features</a></li>
<li><a href="https://github.com/pytorch/pytorch/blob/HEAD/#improvements">Improvements</a></li>
<li><a href="https://github.com/pytorch/pytorch/blob/HEAD/#bug-fixes">Bug fixes</a></li>
<li><a href="https://github.com/pytorch/pytorch/blob/HEAD/#performance">Performance</a></li>
<li><a href="https://github.com/pytorch/pytorch/blob/HEAD/#documentation">Documentation</a></li>
<li><a href="https://github.com/pytorch/pytorch/blob/HEAD/#developers">Developers</a></li>
</ul>
<h1>Highlights</h1>
<!-- raw HTML omitted -->
<p>For more details about these highlighted features, you can look at the release blogpost. Below are the full release notes for this release.</p>
<h1>Tracked Regressions</h1>
<h3>ROCm wheels break <code>torch.compile</code> on CPU in environments without a GPU</h3>
<p>Running a <code>torch==2.13.0+rocm7.2</code> wheel in an environment where no GPU is available (<code>torch.cuda.is_available()</code> is <code>False</code>) breaks <code>torch.compile</code> on the CPU path: the first compile raises <code>RuntimeError: Can't detect vectorized ISA for CPU</code> (<a href="https://redirect.github.com/pytorch/pytorch/issues/189194">#189194</a>). This is a regression from <code>torch==2.12.1+rocm7.2</code>, which compiles CPU code fine (detecting e.g. <code>VecAVX2</code>) in the same setup. The 2.13 ROCm wheel appears to rely on something present in the ROCm builder image to detect the CPU vectorized ISA, so it works when run on a ROCm image but fails on a plain CPU-only image.</p>
<p>Workaround: run the <code>+rocm</code> wheel on a ROCm image, or install a standard CPU/CUDA build for GPU-less environments.</p>
<h1>Backwards Incompatible Changes</h1>
<ul>
<li>
<p>Stop building CPython 3.13t (free-threaded) binaries (<a href="https://redirect.github.com/pytorch/pytorch/issues/182951">#182951</a>)</p>
<p>Upstream <code>pypa/manylinux</code> removed CPython 3.13t (free-threaded) on 2026-05-07, because 3.13t
was experimental and has been superseded by the now-non-experimental CPython 3.14t. As a result,
PyTorch 2.13 no longer ships <code>cp313t</code> wheels (Linux, Triton, and related artifacts). Users on the
free-threaded interpreter should move to Python 3.14t.</p>
<p>PyTorch 2.12:</p>
<pre lang="bash"><code># cp313t (free-threaded 3.13) wheels were available
python3.13t -m pip install torch
</code></pre>
<p>PyTorch 2.13:</p>
</li>
</ul>
<!-- raw HTML omitted -->
</blockquote>
<p>... (truncated)</p>
</details>
<details>
<summary>Commits</summary>
<ul>
<li><a href="https://github.com/pytorch/pytorch/commit/cf30153c4c131c8164ee7798e5022d810682e2cb"><code>cf30153</code></a> [release/2.13] Strip +PTX from CUDA arch list on release/RC builds (<a href="https://redirect.github.com/pytorch/pytorch/issues/188914">#188914</a>) ...</li>
<li><a href="https://github.com/pytorch/pytorch/commit/3e3e24bd95b010f8f74915f0c30476906e60d4fc"><code>3e3e24b</code></a> [release/2.13] Restrict cuda-bindings to Python &lt; 3.15 for CUDA 12.9 builds (...</li>
<li><a href="https://github.com/pytorch/pytorch/commit/7986b068032abf5e22ea51fe7fea63ef5bcaf3b1"><code>7986b06</code></a> [release/2.13] Bump binary build timeout 280 -&gt; 400 minutes (<a href="https://redirect.github.com/pytorch/pytorch/issues/188551">#188551</a>)</li>
<li><a href="https://github.com/pytorch/pytorch/commit/0bdbc268e08fba9debac8f35a8a12e9c008ec0fd"><code>0bdbc26</code></a> [release/2.13] Add CUDA 12.9 to TORCH_CUDA_ARCH_LIST tables (<a href="https://redirect.github.com/pytorch/pytorch/issues/188443">#188443</a>)</li>
<li><a href="https://github.com/pytorch/pytorch/commit/9cabb45ca6e6ed3bb4645c929bcfd07691651f74"><code>9cabb45</code></a> [release/2.13] Update manywheel docker image pin to 78e737ad (<a href="https://redirect.github.com/pytorch/pytorch/issues/188409">#188409</a>)</li>
<li><a href="https://github.com/pytorch/pytorch/commit/78e737ad29420ffc4800e677c51e2a852caf8359"><code>78e737a</code></a> [release/2.13] Revert &quot;Tighten generalized scatter graph target (<a href="https://redirect.github.com/pytorch/pytorch/issues/184075">#184075</a>)&quot; (#...</li>
<li><a href="https://github.com/pytorch/pytorch/commit/0bb9b5bc24bed3278488372d62d9f2235e9e77e3"><code>0bb9b5b</code></a> [release/2.13] Revert &quot;dynamo: round-trip torch.cuda.stream ctx mgr across gr...</li>
<li><a href="https://github.com/pytorch/pytorch/commit/aaac2bfe460c04a4d41e83e03452d2347f7142b9"><code>aaac2bf</code></a> [release/2.13] Revert &quot;[Reland] Port D104346887/PR 182675 for index_add fast ...</li>
<li><a href="https://github.com/pytorch/pytorch/commit/933081368c3ab64fa2e953217e413b3ba52844e3"><code>9330813</code></a> Fix build_with_debinfo.py broken by CONFIGURE_DEPENDS globbing (<a href="https://redirect.github.com/pytorch/pytorch/issues/188192">#188192</a>)</li>
<li><a href="https://github.com/pytorch/pytorch/commit/4e077a7dcf29167db9e97d86cc62f431905e09f7"><code>4e077a7</code></a> Remove setuptools upper bound (<a href="https://redirect.github.com/pytorch/pytorch/issues/188190">#188190</a>)</li>
<li>Additional commits viewable in <a href="https://github.com/pytorch/pytorch/compare/v2.6.0...v2.13.0">compare view</a></li>
</ul>
</details>
<br />


[![Dependabot compatibility score](https://dependabot-badges.githubapp.com/badges/compatibility_score?dependency-name=torch&package-manager=pip&previous-version=2.6.0&new-version=2.13.0)](https://docs.github.com/en/github/managing-security-vulnerabilities/about-dependabot-security-updates#about-compatibility-scores)

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

## timeline-comments 5541603548 by codecov-commenter; https://github.com/NVIDIA/NVFlare/pull/5267#issuecomment-5541603548; ; 
## [Codecov](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5267?dropdown=coverage&src=pr&el=h1&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) Report
:white_check_mark: All modified and coverable lines are covered by tests.
:white_check_mark: Project coverage is 66.57%. Comparing base ([`c277b4e`](https://app.codecov.io/gh/NVIDIA/NVFlare/commit/c277b4ed94c03cc0bc4671798cf4b35ded9085cb?dropdown=coverage&el=desc&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA)) to head ([`ce30be0`](https://app.codecov.io/gh/NVIDIA/NVFlare/commit/ce30be0ada3c6b8e93f4740d763fb4e82128880d?dropdown=coverage&el=desc&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA)).

<details><summary>Additional details and impacted files</summary>



```diff
@@            Coverage Diff             @@
##             main    #5267      +/-   ##
==========================================
+ Coverage   66.55%   66.57%   +0.01%     
==========================================
  Files        1018     1018              
  Lines      105278   105278              
==========================================
+ Hits        70067    70086      +19     
+ Misses      35211    35192      -19     
```

| [Flag](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5267/flags?src=pr&el=flags&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) | Coverage Δ | |
|---|---|---|
| [unit-tests](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5267/flags?src=pr&el=flag&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) | `66.57% <ø> (+0.01%)` | :arrow_up: |

Flags with carried forward coverage won't be shown. [Click here](https://docs.codecov.io/docs/carryforward-flags?utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#carryforward-flags-in-the-pull-request-comment) to find out more.
</details>

[:umbrella: View full report in Codecov by Harness](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5267?dropdown=coverage&src=pr&el=continue&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA).   
:loudspeaker: Have feedback on the report? [Share it here](https://about.codecov.io/codecov-pr-comment-feedback/?utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA).
<details><summary> :rocket: New features to boost your workflow: </summary>

- :snowflake: [Test Analytics](https://docs.codecov.com/docs/test-analytics): Detect flaky tests, report on failures, and find test suite problems.
- :package: [JS Bundle Analysis](https://docs.codecov.com/docs/javascript-bundle-analysis): Save yourself from yourself by tracking and limiting bundle sizes in JS merges.
</details>


## Files
examples/advanced/qwen3-vl/requirements.txt
research/fedcore/requirements.txt