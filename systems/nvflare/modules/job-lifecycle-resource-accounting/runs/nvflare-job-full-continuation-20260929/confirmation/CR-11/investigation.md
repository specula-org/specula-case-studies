# CR-11 Investigation

## Finding

Source: Code Review.

Candidate: overlapping START_JOB handling can make one process-mode job inherit another job's `CUDA_VISIBLE_DEVICES` because `GPUResourceConsumer.consume` writes the client parent process environment before `ProcessJobLauncher.launch_job` copies that environment for the child process.

## Skill records inspected

Pinned skill files read before action:

- `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/skills/bug-confirmation/SKILL.md`
- `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/skills/bug-confirmation/guide.md`
- `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/skills/bug-confirmation/phases/01-investigation.md`
- `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/skills/bug-confirmation/phases/02-reproduction.md`
- `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/skills/bug-confirmation/references/persistent-findings.md`
- `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/skills/bug-confirmation/references/repair-request-format.md`

Continuation records inspected for prior evidence and provenance:

- `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/handoff/conversations/README.md`
- `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/handoff/conversations/index.json`
- Targeted conversation search for `CR-11`, `GPUResourceConsumer`, `CUDA_VISIBLE_DEVICES`, `ProcessJobLauncher`, and overlapping START/resource-consumer wording. Prior records contained the same mechanism under earlier analysis labels; those were treated only as historical evidence and rechecked against the pinned source below.

## Code audit

The default process-mode path intentionally uses the parent process environment as the handoff mechanism. `GPUResourceConsumer.consume` validates GPU IDs and free memory, then writes `os.environ["CUDA_VISIBLE_DEVICES"]` at `nvflare/app_common/resource_consumers/gpu_resource_consumer.py:25-33`. `ProcessJobLauncher.launch_job` later snapshots `os.environ.copy()` at `nvflare/app_common/job_launcher/process_launcher.py:66-81` and passes that snapshot to `spawn_process`.

The START handler sequence leaves a race window between those two operations. `StartJobProcessor.process` allocates resources, calls `resource_consumer.consume(allocated_resources)`, and only then calls `engine.start_app(...)` at `nvflare/private/fed/client/scheduler_cmds.py:114-128`. The resource manager's lock only covers reservation/allocation/free methods (`nvflare/app_common/resource_managers/auto_clean_resource_manager.py:119-172`) and is released before the consumer and launcher run.

The ordinary executor launch lock does not serialize environment consumption and process spawning across jobs. `ClientExecutor.start_app` registers a pending handle under `self.lock`, releases that lock, then calls `job_launcher.launch_job(...)` at `nvflare/private/fed/client/client_executor.py:298-334`.

The server can send START_JOB requests through the normal scheduler/server path (`nvflare/private/fed/server/server_engine.py:1068-1083`). On the client side, transport processing uses thread pools (`nvflare/fuel/f3/sfm/conn_manager.py:90-91`, `:390-396`, `:516-518`), and the admin request dispatcher invokes processors directly, so there is no global START_JOB serialization guard before the client resource consumer.

## Developer intent

The documented intent is per-job GPU separation for concurrent jobs. `docs/user_guide/core_concepts/job.rst:313-316` says the resource consumer sets `CUDA_VISIBLE_DEVICES` to the allocated GPU IDs and that this ensures concurrent jobs use different GPU devices. The process launcher design also documents process mode as `ProcessJobLauncher` plus `GPUResourceManager` plus `GPUResourceConsumer`, where subprocess inheritance of `CUDA_VISIBLE_DEVICES` is the intended behavior (`docs/design/docker_job_launcher_design.md:670-712`).

## Reachability and safeguards

The race does not require a malformed peer message or an impossible state. It requires two jobs with distinct reservation tokens on a client configured with process-mode resource management. A first START_JOB handler can allocate and consume GPU 0, then pause before child launch; a second START_JOB handler can allocate and consume GPU 1, overwriting the parent `CUDA_VISIBLE_DEVICES`; when the first handler resumes, `ProcessJobLauncher.launch_job` copies GPU 1 into the first child's environment.

Cleanup/freeing resources does not repair the already-spawned child environment. There is no downstream launcher guard that compares the allocated resource map with the environment snapshot, and no per-job environment object is passed from `consume` to `launch_job`.

## Novelty search

Within the permitted local source/history scope, I found no exact prior report or fix for this mechanism. Searches covered in-tree references and local git history/blame for `CUDA_VISIBLE_DEVICES`, `GPUResourceConsumer`, resource consumers, `ProcessJobLauncher`, and START_JOB. Related history includes `a54949c1` (`Respect visible GPUs in resource manager (#4563)`), `c6f25218` (`Docker job launcher (#3072)`), `dd256fe9` (`Job launcher (#3049)`), `900f9af3` (`Use PCI_BUS_ID as CUDA_DEVICE_ORDER`), and `31a77288` (`Yield CUDA_VISIBLE_DEVICES settings to users (#99)`), but those changes address visible-GPU bookkeeping, launcher introduction, Docker/K8s mode, ordering, or user-controlled visibility, not overlapping consumer/launcher parent-environment races.

The user explicitly prohibited inspecting newer upstream issue/PR discussions and external answers for this continuation, so novelty is based on the permitted local issue-relevant history, in-tree docs, tests, and prior handoff records only.

## Reproduction plan

The reproduction uses the real `CheckResourceProcessor`, `StartJobProcessor`, `GPUResourceManager`, `GPUResourceConsumer`, and `ProcessJobLauncher`. It supplies a minimal `ClientEngineInternalSpec` implementation because the processors require that interface. The child process is a normal subprocess launched by `ProcessJobLauncher` and records its actual inherited `CUDA_VISIBLE_DEVICES`.

Level 0: attempt normal concurrent START_JOB calls without timing gates and record whether a mismatch appears.

Level 1: add timing assistance only. The first START_JOB handler is paused after `consume` has written GPU 0 and immediately before `launch_job`; the second START_JOB handler then consumes GPU 1 and launches; the first handler resumes and launches. No NVFlare source patch, unreachable state injection, or mock peer message is used. The local test stubs host GPU discovery/free-memory functions so the pinned code can run on this non-GPU confirmation host while preserving the real resource manager/consumer logic.
