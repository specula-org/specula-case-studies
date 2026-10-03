# V01 reference calibration

The user authorized this calibration as the starting model for subsequent CI
updates. This is not a rerun or replacement of the original V00-to-V01 result.
Protocol source remains the previously tested V01 revision.

The sole TLA+ behavior edit changes StepHup's pending-entry scan from ConfKinds
to LegacyConfKinds, matching the supplied source's numOfPendingConf. No invariant
was changed. Reference SHA-256:
`0864a78d767cd3d0d43c6f897a1135472032822967e44a2043fc4fa44cbc6262`.

All eight retained V01 traces were rechecked. Seven passed the unchanged full
Trace.cfg. The known joint-recovery trace passed TraceCorrespondence.cfg; its
previously confirmed ConfigurationOrigin violation remains represented and
enabled in the normal Trace.cfg. See `output/calibration-20260915/results.json`
and its per-scenario logs. This is conformance evidence, not exhaustive proof.

The earlier model-only differential diagnostic used this exact repaired
reference and the existing CampaignDecisionEligibility oracle. It demonstrated
the original guard's masking effect. No new program-level confirmation is
claimed for that diagnostic.

MC-1 and CR-3 retain their completed V01 native confirmation and are registered
as Persistent Findings. Their reusable conclusions are source-level, with
scoped source dependencies and explicit caller/environment premises; no model
operator is executed by those archived native confirmation programs. Historical
evidence is bundled with each record. MC-1's identifier does not imply independent
MC discovery: source analysis preceded its trace/property validation.

The current model, canonical traces, harness, negative traces, and selected
confirmation evidence are retained here. Bulk historical `spec/output` and
`harness/logs` remain in the immutable original publication:
`/home/ubuntu/specula-etcd-ci-init-20260912.FNeLj3NS/ci-clean/runs/20260913-175006-a818/ci-published/2a60d7b4abb490b844844729d5051ccc/model`.
Historical reports in this suite may refer to those archived subdirectories.
Old campaign bookkeeping scripts are not active checking entrypoints.

The run-checks and harness-validation entrypoints now honor SPECULA_ROOT so a
new CI run uses its selected Specula installation. This runtime-path adaptation
does not alter model or trace semantics.
