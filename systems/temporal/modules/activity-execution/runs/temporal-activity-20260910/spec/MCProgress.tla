----------------------- MODULE MCProgress -----------------------
EXTENDS MC
\* A separate healthy suffix: actual millisecond scale and a 1000 ms reader shift.
ProgressClockCandidates ==
  {t.due: t \in s.tasks \cup ToSet(s.newTasks)} \cup
  UNION {{t.due: t \in w.tasks}: w \in s.writes} \cup
  {d.due: d \in Deadlines(s.db) \cup Deadlines(s.cache)} \cup
  {d.expires: d \in s.matching}
ProgressTimes == LET future == {t \in ProgressClockCandidates: t > s.now} IN
  IF future = {} THEN {} ELSE {CHOOSE t \in future: \A u \in future: t <= u}
ProgressAdvanceTime(to) == Original!AdvanceTime(to) /\ UNCHANGED faults
ProgressTaskKeyFloors == {Max(s.keyFloor,s.now+1000)}
ProgressMatchingTimes == {s.now}
ProgressTypeOK == TypeOK /\ DOMAIN faults = DOMAIN Limits /\
  (\A k \in DOMAIN Limits: faults[k] = 0)
ProgressView == [s EXCEPT !.observed = {}, !.historyAppends = {}]
=================================================================
