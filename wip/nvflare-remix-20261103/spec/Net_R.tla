------------------------------- MODULE Net_R -------------------------------
\* Group Net, RELIABLE variant: messages are never lost; delivery order is
\* arbitrary because every receiver may consume any pending message.
EXTENDS Ports
VARIABLE net_r
Init == net_r = 0
Next == FALSE
=============================================================================
