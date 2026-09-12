----------------------- MODULE OracleControls -----------------------
EXTENDS Trace
OracleInit == s = DecodeState(TraceLog[1].state) /\ l = 1
OracleSpec == OracleInit /\ [][UNCHANGED traceVars]_traceVars
=====================================================================
