---- MODULE Test ----
EXTENDS base

TestInit == Init

TestSpec == TestInit /\ [][Next]_vars

====
