------------------------------ MODULE PortsModel ------------------------------
\* Port shape of the MODEL group (v11, profile sjModel; DESIGN 16.5): the SJ's
\* aggregator and persistor as seen by the workflow, pin c411a201.
\*   dxo_aggregator.py:75-208 (can_accept checks, accept -> helper.add, aggregate)
\*   weighted_aggregation_helper.py:192-285 (per-key in-place add, no rollback;
\*     history appended after the loop; get_result divides and resets)
\*   pt/file_model_persistor.py:308-360 (staged write, fsync, replace, dir fsync)
\*   np/np_model_persistor.py:103-114 (np.save on the final path)
\* The workflow (WfSJ) calls the model through pWfSJ.mcall = [n, op, round, site]
\* (op: accept | aggregate | save) and waits for pModel.ret = [n, out].
\* pModel:
\*   ret       : None or [n, out], the reply to call number n
\*   acc[r][c] : none | accepted | rejected | partial (accept raised after it
\*               had mutated part of the accumulator)
\*   poisoned  : rounds whose accumulator holds a partial contribution
\*   agg[r]    : none | clean | poisoned | empty: the aggregate handed out
\*   artifact  : [round, kind], kind initial (round 0) | clean | poisoned | stale
\*               (no contribution, the model was not updated) | corrupt
\*               (a direct write failed midway)
EXTENDS Consts
\* acceptRaise: accept raises after a partial mutation (arithmetic or
\*   materialization error, including a lazy ref whose offload backing is gone).
\* saveFail: the persistor's save raises (before replace, after replace, or
\*   after a partial direct write).
ModelFaults == {"acceptRaise", "saveFail"}
\* the file before the first save (a record, so artifacts compare in TLC)
NoArtifact == [round |-> 0, kind |-> "initial"]
ModelPortInit == IF ~SJModel THEN 0 ELSE
    [ret |-> None, acc |-> [r \in Attempts |-> [c \in Sites |-> "none"]],
     poisoned |-> {}, agg |-> [r \in Attempts |-> "none"], artifact |-> NoArtifact]
=============================================================================
