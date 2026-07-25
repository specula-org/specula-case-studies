// bug79_tautological_invariant.cpp — Demonstrates RethinkDB Bug #79 (CR-1)
//
// Tautological debug invariant at raft_core.tcc:852
//
// Buggy code:
//   guarantee(readiness_for_change.get() || !readiness_for_change.get(),
//       "we shouldn't be accepting config changes but not regular changes");
//
// The expression  p || !p  is always true, so this invariant never fires.
// The intended check was:
//   guarantee(readiness_for_change.get() || !readiness_for_config_change.get(),
//       "we shouldn't be accepting config changes but not regular changes");
//
// This verifies that config changes are only accepted when regular changes
// are also accepted (readiness_for_config_change => readiness_for_change).
//
// Build: g++ -std=c++11 -o bug79_tautological_invariant bug79_tautological_invariant.cpp

#include <cstdio>
#include <cstdlib>

// Simulate the buggy guarantee (tautological: p || !p)
static bool buggy_invariant(bool readiness_for_change, bool /*readiness_for_config_change*/) {
    return readiness_for_change || !readiness_for_change;
}

// Simulate the intended guarantee (correct: change || !config_change)
static bool intended_invariant(bool readiness_for_change, bool readiness_for_config_change) {
    return readiness_for_change || !readiness_for_config_change;
}

int main() {
    printf("=== RethinkDB Bug #79: Tautological Debug Invariant ===\n");
    printf("Location: src/clustering/generic/raft_core.tcc:852\n\n");

    printf("Buggy code:   guarantee(readiness_for_change.get() || !readiness_for_change.get(), ...)\n");
    printf("Intended code: guarantee(readiness_for_change.get() || !readiness_for_config_change.get(), ...)\n\n");

    printf("--- Exhaustive truth table ---\n\n");
    printf("  change  config_change  |  buggy (p||!p)  intended (p||!q)\n");
    printf("  ------  -------------  |  ------------  ----------------\n");

    bool bug_found = false;

    bool vals[] = { false, true };
    for (bool change : vals) {
        for (bool config_change : vals) {
            bool buggy   = buggy_invariant(change, config_change);
            bool correct = intended_invariant(change, config_change);

            printf("  %-5s   %-13s  |  %-13s  %s",
                change ? "true" : "false",
                config_change ? "true" : "false",
                buggy ? "PASS" : "FAIL",
                correct ? "PASS" : "FAIL");

            if (buggy && !correct) {
                printf("  <-- BUG: tautology hides this violation");
                bug_found = true;
            }
            printf("\n");
        }
    }

    printf("\n--- Analysis ---\n\n");

    if (bug_found) {
        printf("BUG CONFIRMED: The tautological invariant (p || !p) always passes.\n");
        printf("When readiness_for_change=false and readiness_for_config_change=true,\n");
        printf("the system accepts config changes but not regular changes.\n");
        printf("The buggy invariant silently passes; the intended check catches it.\n\n");
        printf("Root cause: copy-paste error — both sides of the disjunction reference\n");
        printf("'readiness_for_change' instead of the second referencing\n");
        printf("'readiness_for_config_change'.\n\n");
        printf("Fix: change line 852 from:\n");
        printf("  guarantee(readiness_for_change.get() || !readiness_for_change.get(), ...)\n");
        printf("to:\n");
        printf("  guarantee(readiness_for_change.get() || !readiness_for_config_change.get(), ...)\n");
    } else {
        printf("ERROR: Expected to find a divergence but did not.\n");
        return 1;
    }

    return 0;
}
