# Focused validation — server MC-1

This folder contains the independent focused validation for the async flush
failure finding.

Files:

- `SpeculaAsyncFlushPersistentFailureTest.java`: temporary JUnit test source.
- `focused-test.patch`: diff that adds the temporary test to the clean Ratis source tree.
- `focused-test.out`: command output from the focused validation run.

Result summary:

- Maven result: `BUILD SUCCESS`
- Test result: `Tests run: 1, Failures: 0, Errors: 0, Skipped: 0`
- Fault: every `FileChannel.force(false)` call after installation threw `IOException`
- Observation: `ADMIN_REPLY_SUCCESS=true`, `SUCCESSFUL_FORCE_AFTER_INSTALL=0`, and both `AFTER_COMMIT` and `AFTER_FLUSH` advanced past the target index.
