---- MODULE test_minimal ----

CONSTANT Node, TaskId

VARIABLE in_memory_tasks

Init == in_memory_tasks = [n \in Node |-> {}]

Next == UNCHANGED in_memory_tasks

TestInvariant ==
    \A n \in Node :
        \A t \in in_memory_tasks[n] : TRUE

test_minimal == Init /\ [][Next]_in_memory_tasks

====
