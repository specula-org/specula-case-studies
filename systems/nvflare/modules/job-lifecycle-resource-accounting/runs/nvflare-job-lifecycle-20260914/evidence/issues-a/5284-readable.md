# 5284: Add CoCo provisioning, attestation integration, and deployment guides

{'state': 'OPEN', 'createdAt': '2026-09-11T15:39:50Z', 'updatedAt': '2026-09-12T17:17:38Z', 'headRefOid': '45b5e50a80a1a141249672b2f1cba5876fa53abf', 'baseRefOid': 'e77bf33c1a6975d517362f50d154e7a3aaea67ef', 'closedAt': None, 'mergedAt': None}

## Body
## Summary

- add Confidential Containers (CoCo) provisioning and packaging support
- integrate CoCo attestation authorization into confidential-computing workflows
- add deployment, security, recovery, publication, and operational guides for admin, service, trusted-system, and CoCo hosts
- add unit tests for provisioning, authorization, launch-profile, platform-reference, workload-handoff, and package-validation paths
- reuse shared CoCo configuration constants and YAML loading helpers

## Testing

- Not run as part of PR creation; changes are already committed and pushed on the source branch.

## timeline-comments 5636903735 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5284#issuecomment-5636903735; ; 
<!-- greptile-status -->
Too many files changed for review (145 files, 100 file limit).

Bypass the limit by tagging `@greptile-apps` to review.


## timeline-comments 5637053189 by codecov-commenter; https://github.com/NVIDIA/NVFlare/pull/5284#issuecomment-5637053189; ; 
## [Codecov](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5284?dropdown=coverage&src=pr&el=h1&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) Report
:x: Patch coverage is `87.11485%` with `46 lines` in your changes missing coverage. Please review.
:white_check_mark: Project coverage is 66.61%. Comparing base ([`e77bf33`](https://app.codecov.io/gh/NVIDIA/NVFlare/commit/e77bf33c1a6975d517362f50d154e7a3aaea67ef?dropdown=coverage&el=desc&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA)) to head ([`45b5e50`](https://app.codecov.io/gh/NVIDIA/NVFlare/commit/45b5e50a80a1a141249672b2f1cba5876fa53abf?dropdown=coverage&el=desc&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA)).

| [Files with missing lines](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5284?dropdown=coverage&src=pr&el=tree&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) | Patch % | Lines |
|---|---|---|
| [nvflare/lighter/cc\_provision/impl/coco\_packager.py](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5284?src=pr&el=tree&filepath=nvflare%2Flighter%2Fcc_provision%2Fimpl%2Fcoco_packager.py&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#diff-bnZmbGFyZS9saWdodGVyL2NjX3Byb3Zpc2lvbi9pbXBsL2NvY29fcGFja2FnZXIucHk=) | 84.73% | [20 Missing :warning: ](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5284?src=pr&el=tree&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) |
| [nvflare/lighter/cc\_provision/impl/coco.py](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5284?src=pr&el=tree&filepath=nvflare%2Flighter%2Fcc_provision%2Fimpl%2Fcoco.py&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#diff-bnZmbGFyZS9saWdodGVyL2NjX3Byb3Zpc2lvbi9pbXBsL2NvY28ucHk=) | 86.66% | [14 Missing :warning: ](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5284?src=pr&el=tree&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) |
| [.../app\_opt/confidential\_computing/coco\_authorizer.py](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5284?src=pr&el=tree&filepath=nvflare%2Fapp_opt%2Fconfidential_computing%2Fcoco_authorizer.py&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#diff-bnZmbGFyZS9hcHBfb3B0L2NvbmZpZGVudGlhbF9jb21wdXRpbmcvY29jb19hdXRob3JpemVyLnB5) | 91.74% | [9 Missing :warning: ](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5284?src=pr&el=tree&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) |
| [...flare/app\_opt/confidential\_computing/cc\_manager.py](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5284?src=pr&el=tree&filepath=nvflare%2Fapp_opt%2Fconfidential_computing%2Fcc_manager.py&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#diff-bnZmbGFyZS9hcHBfb3B0L2NvbmZpZGVudGlhbF9jb21wdXRpbmcvY2NfbWFuYWdlci5weQ==) | 0.00% | [1 Missing :warning: ](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5284?src=pr&el=tree&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) |
| [nvflare/lighter/cc\_provision/impl/cc.py](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5284?src=pr&el=tree&filepath=nvflare%2Flighter%2Fcc_provision%2Fimpl%2Fcc.py&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#diff-bnZmbGFyZS9saWdodGVyL2NjX3Byb3Zpc2lvbi9pbXBsL2NjLnB5) | 85.71% | [1 Missing :warning: ](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5284?src=pr&el=tree&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) |
| [nvflare/private/fed/server/fed\_server.py](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5284?src=pr&el=tree&filepath=nvflare%2Fprivate%2Ffed%2Fserver%2Ffed_server.py&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#diff-bnZmbGFyZS9wcml2YXRlL2ZlZC9zZXJ2ZXIvZmVkX3NlcnZlci5weQ==) | 0.00% | [1 Missing :warning: ](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5284?src=pr&el=tree&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) |

<details><summary>Additional details and impacted files</summary>



```diff
@@            Coverage Diff             @@
##              2.9    #5284      +/-   ##
==========================================
+ Coverage   66.50%   66.61%   +0.11%     
==========================================
  Files        1016     1019       +3     
  Lines      105198   105553     +355     
==========================================
+ Hits        69959    70312     +353     
- Misses      35239    35241       +2     
```

| [Flag](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5284/flags?src=pr&el=flags&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) | Coverage Δ | |
|---|---|---|
| [unit-tests](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5284/flags?src=pr&el=flag&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) | `66.61% <87.11%> (+0.11%)` | :arrow_up: |

Flags with carried forward coverage won't be shown. [Click here](https://docs.codecov.io/docs/carryforward-flags?utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#carryforward-flags-in-the-pull-request-comment) to find out more.
</details>

[:umbrella: View full report in Codecov by Harness](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5284?dropdown=coverage&src=pr&el=continue&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA).   
:loudspeaker: Have feedback on the report? [Share it here](https://about.codecov.io/codecov-pr-comment-feedback/?utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA).
<details><summary> :rocket: New features to boost your workflow: </summary>

- :snowflake: [Test Analytics](https://docs.codecov.com/docs/test-analytics): Detect flaky tests, report on failures, and find test suite problems.
- :package: [JS Bundle Analysis](https://docs.codecov.com/docs/javascript-bundle-analysis): Save yourself from yourself by tracking and limiting bundle sizes in JS merges.
</details>


## reviews 5180686575 by copilot-pull-request-reviewer[bot]; https://github.com/NVIDIA/NVFlare/pull/5284#pullrequestreview-5180686575; COMMENTED; 
### 🟡 Changes recommended

One or more issues must be addressed before approval.

*Once you've addressed the issues Copilot identified, you can request another Copilot review.*

<details>
<summary>Pull request overview</summary>

Adds Confidential Containers provisioning, attestation authorization, trusted-system workflows, deployment guides, and validation tests for NVFlare.

**Changes:**
- Adds CoCo builders, packaging, attestation authorization, and client identity propagation.
- Adds admin, service, CoCo-host, and trusted-system deployment/recovery workflows.
- Adds offline package validation and unit tests.
</details>

<details>
<summary>File summaries</summary>

| File | Description |
| ---- | ----------- |
| nvflare/private/fed/server/fed_server.py | Updated as part of this pull request. |
| nvflare/lighter/provision.py | Updated as part of this pull request. |
| nvflare/lighter/cc_provision/impl/cc.py | Updated as part of this pull request. |
| nvflare/lighter/cc_provision/cc_constants.py | Updated as part of this pull request. |
| examples/devops/coco/validate-package.py | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/workload-source.yaml.example | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/TEARDOWN.md | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/sec-sys-launch-profile.env.example | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/rehearsal-collector/Dockerfile | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/rehearsal-collector/collect-snp-evidence.sh | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/record-reported-tcb.sh | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/README.md | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/LOCAL-MACHINE-REDEPLOY.md | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/lib/validate-config.sh | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/GPU-VERIFICATION.md | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/gpu-probe.c | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/export-workload-launch-profile.py | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/CURRENT-STATE.md | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/capture-running-launch.py | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/bootstrap/templates/kubeadm.yaml.in | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/bootstrap/README.md | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/bootstrap/lib/common.sh | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/bootstrap/config.env.example | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/10-export-platform-reference-values.sh | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/06-prepare-platform-reference.sh | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/05-define-approved-launch-profile.py | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/04-install-rehearsal-runtime.sh | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/03-fetch-kata-artifacts.sh | Updated as part of this pull request. |
| examples/devops/coco/trusted_system/01-install-rehearsal-host-tools.sh | Updated as part of this pull request. |
| examples/devops/coco/tests/test_provision_scripts.py | Updated as part of this pull request. |
| examples/devops/coco/service/TRUSTED-HANDOFF-RUNBOOK.md | Updated as part of this pull request. |
| examples/devops/coco/service/SNP-TCB-POLICY.md | Updated as part of this pull request. |
| examples/devops/coco/service/SERVICE-MACHINE-REDEPLOY.md | Updated as part of this pull request. |
| examples/devops/coco/service/SECURITY.md | Updated as part of this pull request. |
| examples/devops/coco/service/README.md | Updated as part of this pull request. |
| examples/devops/coco/service/public/README.md | Updated as part of this pull request. |
| examples/devops/coco/service/policies/workload-resource-policy.rego.template | Updated as part of this pull request. |
| examples/devops/coco/service/policies/default-deny-resource-policy.rego | Updated as part of this pull request. |
| examples/devops/coco/service/policies/default_cpu.rego | Updated as part of this pull request. |
| examples/devops/coco/service/platform.env.example | Updated as part of this pull request. |
| examples/devops/coco/service/MEASUREMENT-ALLOWLIST.md | Updated as part of this pull request. |
| examples/devops/coco/service/lib/validate-config.sh | Updated as part of this pull request. |
| examples/devops/coco/service/lib/common.sh | Updated as part of this pull request. |
| examples/devops/coco/service/CURRENT-STATE.md | Updated as part of this pull request. |
| examples/devops/coco/service/config/rvps-localfs.json | Updated as part of this pull request. |
| examples/devops/coco/service/13-verify-workload-release.sh | Updated as part of this pull request. |
| examples/devops/coco/service/11-verify-service.sh | Updated as part of this pull request. |
| examples/devops/coco/service/10-verify-platform-reference-values.sh | Updated as part of this pull request. |
| examples/devops/coco/service/09-install-platform-policy.sh | Updated as part of this pull request. |
| examples/devops/coco/service/07-harden-kbs-admin-audience.sh | Updated as part of this pull request. |
| examples/devops/coco/service/06-configure-trustee-tls.sh | Updated as part of this pull request. |
| examples/devops/coco/service/05-deploy-trustee.sh | Updated as part of this pull request. |
| examples/devops/coco/service/03-preflight.sh | Updated as part of this pull request. |
| examples/devops/coco/service/02-install-platform-reference-values.sh | Updated as part of this pull request. |
| examples/devops/coco/service/01-install-host-tools.sh | Updated as part of this pull request. |
| examples/devops/coco/README.md | Updated as part of this pull request. |
| examples/devops/coco/PUBLICATION.md | Updated as part of this pull request. |
| examples/devops/coco/provision/site-1/Dockerfile | Updated as part of this pull request. |
| examples/devops/coco/provision/project.yaml | Updated as part of this pull request. |
| examples/devops/coco/provision/cc_site-1.yml | Updated as part of this pull request. |
| examples/devops/coco/PACKAGE-FILES.txt | Updated as part of this pull request. |
| examples/devops/coco/docs/coco-security-design-3-slides.md | Updated as part of this pull request. |
| examples/devops/coco/coco/SECURITY.md | Updated as part of this pull request. |
| examples/devops/coco/coco/README.md | Updated as part of this pull request. |
| examples/devops/coco/coco/public/README.md | Updated as part of this pull request. |
| examples/devops/coco/coco/public/kata-platform.env | Updated as part of this pull request. |
| examples/devops/coco/coco/platform.env.example | Updated as part of this pull request. |
| examples/devops/coco/coco/lib/validate-config.sh | Updated as part of this pull request. |
| examples/devops/coco/coco/lib/common.sh | Updated as part of this pull request. |
| examples/devops/coco/coco/CURRENT-STATE.md | Updated as part of this pull request. |
| examples/devops/coco/coco/config.env.example | Updated as part of this pull request. |
| examples/devops/coco/coco/COCO-IT-RUNBOOK.md | Updated as part of this pull request. |
| examples/devops/coco/coco/bootstrap/templates/kubeadm.yaml.in | Updated as part of this pull request. |
| examples/devops/coco/coco/bootstrap/README.md | Updated as part of this pull request. |
| examples/devops/coco/coco/bootstrap/lib/common.sh | Updated as part of this pull request. |
| examples/devops/coco/coco/70-verify-running-workload.sh | Updated as part of this pull request. |
| examples/devops/coco/coco/60-verify-platform.sh | Updated as part of this pull request. |
| examples/devops/coco/coco/40-configure-registry-trust.sh | Updated as part of this pull request. |
| examples/devops/coco/coco/35-repin-kata-deployment.sh | Updated as part of this pull request. |
| examples/devops/coco/coco/30-install-coco-gpu.sh | Updated as part of this pull request. |
| examples/devops/coco/coco/20-install-kubernetes.sh | Updated as part of this pull request. |
| examples/devops/coco/coco/10-run-host-preflight.sh | Updated as part of this pull request. |
| examples/devops/coco/coco/00-fetch-pinned-workflow.sh | Updated as part of this pull request. |
| examples/devops/coco/admin/workload.example.env | Updated as part of this pull request. |
| examples/devops/coco/admin/tests/test_launch_profile_export.py | Updated as part of this pull request. |
| examples/devops/coco/admin/SECURITY-MODEL.md | Updated as part of this pull request. |
| examples/devops/coco/admin/public/README.md | Updated as part of this pull request. |
| examples/devops/coco/admin/platform.env.example | Updated as part of this pull request. |
| examples/devops/coco/admin/lib/validate-config.sh | Updated as part of this pull request. |
| examples/devops/coco/admin/lib/release.sh | Updated as part of this pull request. |
| examples/devops/coco/admin/lib/platform.sh | Updated as part of this pull request. |
| examples/devops/coco/admin/example-workload/main.go | Updated as part of this pull request. |
| examples/devops/coco/admin/example-workload/Dockerfile | Updated as part of this pull request. |
| examples/devops/coco/admin/example-workload/build-example.sh | Updated as part of this pull request. |
| examples/devops/coco/admin/CURRENT-STATE.md | Updated as part of this pull request. |
| examples/devops/coco/admin/COCO-IT-RUNBOOK.md | Updated as part of this pull request. |
| examples/devops/coco/admin/build_coco_image.sh | Updated as part of this pull request. |
| examples/devops/coco/admin/APPROVED-LAUNCH-PROFILE.md | Updated as part of this pull request. |
| examples/devops/coco/admin/40-create-handoffs.sh | Updated as part of this pull request. |
| examples/devops/coco/admin/31-recover-failed-policy-generation.sh | Updated as part of this pull request. |
| examples/devops/coco/admin/25-verify-published-image.sh | Updated as part of this pull request. |
| examples/devops/coco/admin/10-build-plaintext.sh | Updated as part of this pull request. |
| examples/devops/coco/admin/05-install-publisher-credential.sh | Updated as part of this pull request. |
| examples/devops/coco/admin/00-install-tools.sh | Updated as part of this pull request. |
| examples/devops/coco/.gitignore | Updated as part of this pull request. |
</details>

<details>
<summary>Review details</summary>

### Suppressed comments (9)

**examples/devops/coco/admin/20-encrypt-sign-publish.sh:69**
* A fixed two-second delay does not establish that `coco_keyprovider` is listening. On a cold or resource-constrained admin host, the following `skopeo copy` can race provider startup and fail valid releases intermittently. Poll the provider's readiness socket with a bounded timeout, or retry the copy with cleanup of any partial encrypted output.
```
        sleep 2
```
**examples/devops/coco/trusted_system/07-run-snp-rehearsal.sh:217**
* The approved profile normalizes GPU limits into GPU requests, but this rehearsal path copies the source YAML's resource block without that normalization. With the checked-in workload example (limits only), stage 07 records `pod_resources` without requests while stage 05 records them with a request; stage 09 then fails its exact equality check and the documented workflow cannot finalize.
**examples/devops/coco/trusted_system/09-finalize-platform-reference.sh:211**
* The policy defines these values as minimum floors, so a signed report with a newer TCB must satisfy them when each reported component is greater than or equal to its floor. Exact string equality rejects valid newer firmware and, combined with the report-derived assignments above, prevents independently approved floors from working.
**examples/devops/coco/trusted_system/09-finalize-platform-reference.sh:244**
* The documented workflow requires the stage-08 repeat rehearsal before accepting or exporting a profile, but stage 09 never checks for a successful repeat result and can create `platform-reference.final.env` after only stage 07. This makes the stated repeatability gate optional in practice; finalization should require and validate the repeat evidence or the documentation should stop treating it as mandatory.
**examples/devops/coco/trusted_system/09-finalize-platform-reference.sh:132**
* The approved profile adds default GPU requests from the source limits in stage 05, but stage 07 copies the source resource map without those defaults. With the checked-in workload template (limits only), `actual['pod_resources']` therefore omits `requests` and this comparison aborts every normal stage-09 finalization. Apply the same normalization when building the collector Pod (or otherwise compare the same canonical resource shape) so stage 09 and the exporter agree.
**examples/devops/coco/trusted_system/09-finalize-platform-reference.sh:126**
* Stage 05 records `workload_yaml_sha256` in the approved launch profile, but finalization only checks the current source hash against the rehearsal evidence. It never compares that hash with the approved profile, so the source can be changed after profile approval (including fields the rehearsal script ignores) while finalization still succeeds. Validate the current source against `approved-launch-profile.json` before producing the final environment.
**examples/devops/coco/trusted_system/README.md:70**
* The new sentence has a subject-verb agreement error: “secure services” is plural, so it should use “receive,” not “receives.”
**nvflare/lighter/cc_provision/impl/coco.py:39**
* When `cc_config` is relative, this fallback uses the process working directory. The normal `nvflare provision` wrapper now sets `_project_file`, but the POC provisioning callers invoke `prepare_project` directly (for example `nvflare/tool/poc/poc_commands.py:382`) without setting it, even though the POC project is saved under its workspace. A CoCo POC project with `cc_config: cc_site-1.yml` therefore fails unless launched from the config directory; pass the source project path into the `Project` or make all provisioning entry points set `_project_file`.
**nvflare/lighter/cc_provision/impl/coco_packager.py:188**
* This setting is propagated into the generated Pod, but `coco/50-launch-handoff.sh` rejects any handoff whose `securityContext.readOnlyRootFilesystem` is false. Since the NVFlare CoCo packager always sets this to false, every generated client handoff is rejected before it can be applied. Align the runtime's writable-state requirement with the launch validator and profile before publishing the handoff.

- **Files reviewed:** 143/145 changed files
- **Comments generated:** 6
- **Review effort level:** Lite
</details>

---

💡 <a href="/NVIDIA/NVFlare/new/2.9?filename=.github/skills/code-review/SKILL.md" class="Link--inTextBlock" target="_blank" rel="noopener noreferrer">Add a `code-review` agent skill</a> or configure MCP servers for context-aware, tailored reviews. <a href="https://docs.github.com/copilot/how-tos/use-copilot-agents/request-a-code-review/use-code-review?tool=webui#mcp-servers-and-agent-skills" class="Link--inTextBlock" target="_blank" rel="noopener noreferrer">Learn more in the docs.</a>


## reviews 5187330477 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5284#pullrequestreview-5187330477; COMMENTED; 

• I found four issues in PR #5284 at 45b5e50a. I would request changes.

  1. [P1] Attestation is not bound to the client presenting it.
     CoCoAuthorizer.verify() (/private/tmp/nvflare-pr5284-review/nvflare/app_opt/confidential_computing/coco_authorizer.py:195) checks only that sub is nonempty. I reproduced a site-1 proof
     being accepted for site-2. More seriously, registration accepts CC_INFO={"server.example.com": []} from a protected client because CCManager skips names outside cc_enabled_sites. The newly
     populated CLIENT_NAME is never checked by CCManager. Bind the envelope and signed subject to the authenticated participant, and require its expected attestation.

  2. [P1] The launcher rejects every provisioned NVFlare Pod.
     The packager explicitly sets APP_READ_ONLY_ROOT_FILESYSTEM=false because NVFlare needs writable runtime storage. However, /private/tmp/nvflare-pr5284-review/examples/devops/coco/coco/50-
     launch-handoff.sh:75 requires readOnlyRootFilesystem=True. I reproduced the generated Pod failing this check before deployment. The launcher needs to support the approved writable NVFlare
     configuration.

  3. [P1] Ordinary clients trigger the server’s shutdown path.
     CoCoBuilder (/private/tmp/nvflare-pr5284-review/nvflare/lighter/cc_provision/impl/coco.py:170) installs CCManager on the server while leaving ordinary clients without CCManager. When an
     ordinary client registers without CC_INFO, the server calls _shutdown_system("No peer CC info!") before checking whether that client requires attestation. This contradicts the documented
     mixed-client support. Check the authenticated client’s CC requirement before demanding tokens.

  4. [P2] The public package checksum manifest is stale.
     Sixteen files differ from /private/tmp/nvflare-pr5284-review/examples/devops/coco/PACKAGE-SHA256SUMS:27, including the launch-profile validator and provisioning documentation.
     Consequently, the documented package validation fails even on clean source. Regenerate the checksums after the final changes.



## inline-comments 3990919771 by Copilot; https://github.com/NVIDIA/NVFlare/pull/5284#discussion_r3990919771; ; examples/devops/coco/trusted_system/09-finalize-platform-reference.sh
This comparison maps `firmware`, `kernel`, `initrd`, and `image` to the `configured_*` entries, even though `capture-running-launch.py` records the actual `-bios`/`-kernel`/`-initrd` files under the unprefixed keys. Finalization therefore rehashes the configured paths instead of the files QEMU actually launched with, so a launch using a different runtime artifact can pass the approval step. Compare each approved artifact with its actual captured artifact (and handle the rootfs/image case explicitly) before exporting the platform reference.


## inline-comments 3990919873 by Copilot; https://github.com/NVIDIA/NVFlare/pull/5284#discussion_r3990919873; ; examples/devops/coco/trusted_system/record-reported-tcb.sh
These assignments make the platform security baseline equal to whatever TCB the rehearsal happens to report. Stage 06 creates these fields as blanks and stage 07 calls this helper before finalization, so a lower-TCB report can silently become the approved floor; the service policy documentation requires floors to be set independently and says an attestation report must not define them. Leave these approval fields for an independently reviewed input and only validate the report against them.


## inline-comments 3990919918 by Copilot; https://github.com/NVIDIA/NVFlare/pull/5284#discussion_r3990919918; ; examples/devops/coco/service/12-install-trusted-service-handoff.sh
`sha256sum --check` validates only the entries present in `SHA256SUMS`; it does not require the manifest to cover all five payload files. An altered manifest can omit `image_key` (or another expected file) and this check still passes even though the directory contains all six expected files. Validate that the checksum names are exactly the five non-manifest handoff files before checking their digests.


## inline-comments 3990919968 by Copilot; https://github.com/NVIDIA/NVFlare/pull/5284#discussion_r3990919968; ; examples/devops/coco/admin/APPROVED-LAUNCH-PROFILE.md
The phrase "trusted trusted_system channel" repeats the system name and reads as a typo in this new guide.


## inline-comments 3990920001 by Copilot; https://github.com/NVIDIA/NVFlare/pull/5284#discussion_r3990920001; ; examples/devops/coco/trusted_system/GPU-VERIFICATION.md
The phrase "trusted trusted_system host" repeats the system name and reads as a typo in this new guide.


## inline-comments 3990920045 by Copilot; https://github.com/NVIDIA/NVFlare/pull/5284#discussion_r3990920045; ; examples/devops/coco/trusted_system/README.md
The phrase "trusted trusted_system machine" repeats the system name and reads as a typo in this new guide.


## Files
examples/devops/coco/.gitignore
examples/devops/coco/CONFIGURATION.md
examples/devops/coco/PACKAGE-FILES.txt
examples/devops/coco/PACKAGE-SHA256SUMS
examples/devops/coco/PUBLICATION.md
examples/devops/coco/README.md
examples/devops/coco/admin/00-install-tools.sh
examples/devops/coco/admin/05-install-publisher-credential.sh
examples/devops/coco/admin/10-build-plaintext.sh
examples/devops/coco/admin/20-encrypt-sign-publish.sh
examples/devops/coco/admin/25-verify-published-image.sh
examples/devops/coco/admin/30-generate-pod-and-policies.sh
examples/devops/coco/admin/31-recover-failed-policy-generation.sh
examples/devops/coco/admin/40-create-handoffs.sh
examples/devops/coco/admin/ADMIN-MACHINE-REDEPLOY.md
examples/devops/coco/admin/APPROVED-LAUNCH-PROFILE.md
examples/devops/coco/admin/COCO-IT-RUNBOOK.md
examples/devops/coco/admin/CURRENT-STATE.md
examples/devops/coco/admin/README.md
examples/devops/coco/admin/SECURITY-MODEL.md
examples/devops/coco/admin/build_coco_image.sh
examples/devops/coco/admin/example-workload/Dockerfile
examples/devops/coco/admin/example-workload/build-example.sh
examples/devops/coco/admin/example-workload/main.go
examples/devops/coco/admin/lib/platform.sh
examples/devops/coco/admin/lib/release.sh
examples/devops/coco/admin/lib/validate-config.sh
examples/devops/coco/admin/lib/workload-launch-profile.py
examples/devops/coco/admin/platform.env.example
examples/devops/coco/admin/public/README.md
examples/devops/coco/admin/tests/test_launch_profile_export.py
examples/devops/coco/admin/tests/test_workload_launch_profile.py
examples/devops/coco/admin/workload.example.env
examples/devops/coco/coco/00-fetch-pinned-workflow.sh
examples/devops/coco/coco/10-run-host-preflight.sh
examples/devops/coco/coco/20-install-kubernetes.sh
examples/devops/coco/coco/30-install-coco-gpu.sh
examples/devops/coco/coco/35-repin-kata-deployment.sh
examples/devops/coco/coco/40-configure-registry-trust.sh
examples/devops/coco/coco/50-launch-handoff.sh
examples/devops/coco/coco/60-verify-platform.sh
examples/devops/coco/coco/70-verify-running-workload.sh
examples/devops/coco/coco/COCO-IT-RUNBOOK.md
examples/devops/coco/coco/COCO-MACHINE-REDEPLOY.md
examples/devops/coco/coco/CURRENT-STATE.md
examples/devops/coco/coco/README.md
examples/devops/coco/coco/SECURITY.md
examples/devops/coco/coco/bootstrap/00-verify-host.sh
examples/devops/coco/coco/bootstrap/10-install-kubernetes.sh
examples/devops/coco/coco/bootstrap/20-install-coco-gpu.sh
examples/devops/coco/coco/bootstrap/README.md
examples/devops/coco/coco/bootstrap/lib/common.sh
examples/devops/coco/coco/bootstrap/templates/kubeadm.yaml.in
examples/devops/coco/coco/config.env.example
examples/devops/coco/coco/lib/common.sh
examples/devops/coco/coco/lib/validate-config.sh
examples/devops/coco/coco/platform.env.example
examples/devops/coco/coco/public/README.md
examples/devops/coco/coco/public/kata-platform.env
examples/devops/coco/docs/coco-security-design-3-slides.html
examples/devops/coco/docs/coco-security-design-3-slides.md
examples/devops/coco/docs/coco-security-design-3-slides.pdf
examples/devops/coco/docs/coco-security-design-3-slides.pptx
examples/devops/coco/provision/CCMANAGER.md
examples/devops/coco/provision/README.md
examples/devops/coco/provision/cc_site-1.yml
examples/devops/coco/provision/project.yaml
examples/devops/coco/provision/site-1/Dockerfile
examples/devops/coco/service/01-install-host-tools.sh
examples/devops/coco/service/02-install-platform-reference-values.sh
examples/devops/coco/service/03-preflight.sh
examples/devops/coco/service/04-build-trustee-main.sh
examples/devops/coco/service/05-deploy-trustee.sh
examples/devops/coco/service/06-configure-trustee-tls.sh
examples/devops/coco/service/07-harden-kbs-admin-audience.sh
examples/devops/coco/service/08-deploy-private-registry.sh
examples/devops/coco/service/09-install-platform-policy.sh
examples/devops/coco/service/10-verify-platform-reference-values.sh
examples/devops/coco/service/11-verify-service.sh
examples/devops/coco/service/12-install-trusted-service-handoff.sh
examples/devops/coco/service/13-verify-workload-release.sh
examples/devops/coco/service/CURRENT-STATE.md
examples/devops/coco/service/MEASUREMENT-ALLOWLIST.md
examples/devops/coco/service/PLATFORM-REFERENCE-VALUES-HANDOFF.md
examples/devops/coco/service/README.md
examples/devops/coco/service/SECURITY.md
examples/devops/coco/service/SERVICE-INSTALLATION.md
examples/devops/coco/service/SERVICE-MACHINE-REDEPLOY.md
examples/devops/coco/service/SNP-TCB-POLICY.md
examples/devops/coco/service/TRUSTED-HANDOFF-RUNBOOK.md
examples/devops/coco/service/config/rvps-localfs.json
examples/devops/coco/service/lib/common.sh
examples/devops/coco/service/lib/platform-reference-values.py
examples/devops/coco/service/lib/validate-config.sh
examples/devops/coco/service/platform.env.example
examples/devops/coco/service/policies/default-deny-resource-policy.rego
examples/devops/coco/service/policies/default_cpu.rego
examples/devops/coco/service/policies/workload-resource-policy.rego.template
examples/devops/coco/service/public/README.md
examples/devops/coco/service/tests/test_platform_reference_values.py