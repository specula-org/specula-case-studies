---------------- MODULE CfgCheck ----------------
EXTENDS MC
InitOnlyNext == UNCHANGED mcvars
InitOnlySpec == MCInit /\ [][InitOnlyNext]_mcvars
=================================================
