--------------------------------- MODULE AG ---------------------------------
\* Discharge of the assume-guarantee environment assumptions (DESIGN.md §2.1).
\* AG_<G> must hold in every mix whose conclusions rely on G's harness receipt:
\* every step of the composition changes G's reads only as G's environment
\* assumption (checker form EnvAllowed) permits.
EXTENDS Ports
ETrainer == INSTANCE Env_Trainer WITH MaxGen <- 0   \* MaxGen bounds only the generator
AG_Trainer == [][ETrainer!EnvAllowed]_portVars
ERunCJ == INSTANCE Env_RunCJ
AG_RunCJ == [][ERunCJ!EnvAllowed]_portVars
EPay == INSTANCE Env_Pay
AG_Pay == [][EPay!EnvAllowed]_portVars
EWfSJ == INSTANCE Env_WfSJ
AG_WfSJ == [][EWfSJ!EnvAllowed]_portVars
=============================================================================
