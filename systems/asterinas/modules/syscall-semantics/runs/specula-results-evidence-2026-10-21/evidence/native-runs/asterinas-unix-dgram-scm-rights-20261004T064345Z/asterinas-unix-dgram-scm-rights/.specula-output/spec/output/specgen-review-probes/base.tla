---- MODULE base ----
EXTENDS Naturals, Integers, Sequences, FiniteSets, TLC

\* Category B. Asterinas 0c60537098f4c2949ad2d382aaf499de72263d76.
\* Source paths are relative to kernel/core/src/ unless prefixed OSTD or Linux.
\* One nonempty datagram, ordinary FileLike objects, stable disjoint buffers.
\* Linux is an external contract oracle, not an alternative scheduler here.
\* In particular, its longer receive iolock is not imposed on Asterinas.

CONSTANTS Threads, AttemptSlots, RightsCount, ObjectA, ObjectB,
          SharedTable, SetupFDCount, MaxFD, PayloadSize

Objects == {ObjectA, ObjectB}
Entries == 1..RightsCount
Ops == Threads \X (1..AttemptSlots)
SenderTable == IF SharedTable THEN "shared" ELSE "sender"
ReceiverTable == IF SharedTable THEN "shared" ELSE "receiver"
Tables == {SenderTable, ReceiverTable}
FDs == 0..MaxFD
Slots == Tables \X FDs
SenderA == <<SenderTable, SetupFDCount>>
SenderB == <<SenderTable, SetupFDCount + 1>>
SendSlot(i) == IF i % 2 = 1 THEN SenderA ELSE SenderB
ExpectedObjects == [i \in Entries |-> IF i % 2 = 1 THEN ObjectA ELSE ObjectB]
NoObject == "NoObject"
NoMessage == "NoMessage"
Message == "message1"
NoOwner == "NoOwner"
HeaderBytes == 16
FDBytes == 4
Alignment == 8
Min(a, b) == IF a < b THEN a ELSE b
Align(n) == ((n + Alignment - 1) \div Alignment) * Alignment
Count(seq, obj) == Cardinality({i \in DOMAIN seq : seq[i] = obj})
SeqSet(seq) == {seq[i] : i \in DOMAIN seq}
ByteRange(start, count) == start..(start + count - 1)

\* S3: concrete static layouts from contracts SCM-03..07/09.
\* ctrl_msg.rs:117-135; OSTD ostd/src/mm/io/mod.rs:795-808.
\* Byte effects are copy coverage, not a claim that the writer cursor is memory.
LayoutNames == {"Full", "Null", "Zero", "Short", "HeaderOnly", "NoInteger",
                "One", "OnePadded", "SpaceOne", "FirstFault", "LaterFault",
                "PartialFault", "HeaderFault", "HeaderPartial"}
Layout(name) ==
    [name |-> name,
     null |-> name = "Null",
     capacity |-> CASE name = "Zero" -> 0
                   [] name = "Short" -> 15
                   [] name = "HeaderOnly" -> 16
                   [] name = "NoInteger" -> 19
                   [] name = "One" -> 20
                   [] name = "OnePadded" -> 21
                   [] name = "SpaceOne" -> 24
                   [] OTHER -> HeaderBytes + FDBytes * RightsCount,
     headerCopied |-> CASE name = "HeaderFault" -> 0
                       [] name = "HeaderPartial" -> 8
                       [] OTHER -> HeaderBytes,
     failEntry |-> CASE name = "FirstFault" -> 1
                    [] name \in {"LaterFault", "PartialFault"} -> 3
                    [] OTHER -> 0,
     partialBytes |-> IF name = "PartialFault" THEN 2 ELSE 0]
CapacityCount(layout) ==
    IF layout.null \/ layout.capacity < HeaderBytes THEN 0
    ELSE Min(RightsCount, (layout.capacity - HeaderBytes) \div FDBytes)
OutputFault(layout) ==
    layout.headerCopied < HeaderBytes \/ layout.failEntry > 0

\* S1: the table owns each occupied slot once, even when roles share it.
\* file_table.rs:190-205,274-297. S2/S3 locals retain independent references.
VARIABLES send, queue, rx, fdTable, fdOrigin, closing, refBalance,
          releasedEntries, cleanupRequested, senderReused
vars == <<send, queue, rx, fdTable, fdOrigin, closing, refBalance,
          releasedEntries, cleanupRequested, senderReused>>
tableVars == <<fdTable, fdOrigin, closing, releasedEntries>>
environmentVars == <<cleanupRequested, senderReused>>

EmptyReceiver ==
    [pc |-> "Idle", mode |-> "Recv", layout |-> Layout("Full"),
     payloadGood |-> TRUE, selected |-> NoMessage, payloadResult |-> "Pending",
     selectedRef |-> <<>>, temp |-> <<>>, nfit |-> 0, index |-> 1,
     fdForEntry |-> [i \in Entries |-> -1],
     installedObjects |-> [i \in Entries |-> NoObject],
     installed |-> {}, numberComplete |-> {}, numberFailed |-> {},
     delivered |-> {}, dirtyBytes |-> {}, cursor |-> 0,
     headerResult |-> "Unattempted", headerLen |-> 0,
     controlError |-> "", internalLen |-> 0, ctrunc |-> FALSE,
     reportedLen |-> 0, reportedCtrunc |-> FALSE, msghdrWritten |-> FALSE,
     returnValue |-> "Pending", faultRetained |-> FALSE,
     generated |-> FALSE, peekBefore |-> <<>>, peekAfter |-> <<>>,
     peekMessageBefore |-> NoMessage, peekMessageAfter |-> NoMessage,
     generatedObjects |-> <<>>]

InitialObject(s) ==
    IF s = SenderA THEN ObjectA
    ELSE IF s = SenderB THEN ObjectB
    ELSE IF s[2] < SetupFDCount THEN "External" ELSE NoObject

\* Fixture initialization, before sys_sendmsg.rs:23-40.
\* Socket/test-control FDs are External, outside ordinary-object accounting.
Init ==
    /\ send = [pc |-> "Idle", temp |-> <<>>, capturedObjects |-> <<>>,
               payloadGood |-> TRUE, result |-> "Pending"]
    /\ queue = [msg |-> NoMessage, rights |-> <<>>, lock |-> NoOwner,
                enqueued |-> FALSE, consumed |-> 0, disposed |-> 0,
                disposeTemp |-> <<>>, closed |-> FALSE]
    /\ rx = [o \in Ops |-> EmptyReceiver]
    /\ fdTable = [s \in Slots |-> InitialObject(s)]
    /\ fdOrigin = [s \in Slots |-> IF s \in {SenderA, SenderB}
                                  THEN "Sender" ELSE "Other"]
    /\ closing = [s \in Slots |-> NoObject]
    /\ refBalance = [obj \in Objects |-> 1]
    /\ releasedEntries = {}
    /\ cleanupRequested = FALSE
    /\ senderReused = FALSE

\* S1/SCM-14: faults are arranged before entry, never injected mid-copy.
\* sys_sendmsg.rs:23-40,51-59; datagram/message.rs:81.
SendBegin(good) ==
    /\ send.pc = "Idle"
    /\ good \in BOOLEAN
    /\ send' = [send EXCEPT !.pc = "Capture", !.payloadGood = good]
    /\ UNCHANGED <<queue, rx, tableVars, refBalance, environmentVars>>

\* ctrl_msg.rs:103-110 and file_table.rs:355-360: one owned capture per entry.
FileMessageReadFrom ==
    /\ send.pc = "Capture"
    /\ Len(send.temp) < RightsCount
    /\ LET i == Len(send.temp) + 1
           obj == fdTable[SendSlot(i)]
       IN /\ obj \in Objects
          /\ send' = [send EXCEPT !.temp = Append(@, obj),
                                 !.capturedObjects = Append(@, obj)]
          /\ refBalance' = [refBalance EXCEPT ![obj] = @ + 1]
    /\ UNCHANGED <<queue, rx, tableVars, environmentVars>>

\* ctrl_msg.rs:222-240: the sole FileMessage list moves into AuxiliaryData.
AuxiliaryDataFromControl ==
    /\ send.pc = "Capture" /\ Len(send.temp) = RightsCount
    /\ send' = [send EXCEPT !.pc = "Lock"]
    /\ UNCHANGED <<queue, rx, tableVars, refBalance, environmentVars>>

\* datagram/message.rs:60-77: bounded fixture has space and no shutdown.
MessageQueueTrySendLock ==
    /\ send.pc = "Lock" /\ queue.lock = NoOwner /\ ~queue.closed
    /\ queue' = [queue EXCEPT !.lock = "Sender"]
    /\ send' = [send EXCEPT !.pc = "Copy"]
    /\ UNCHANGED <<rx, tableVars, refBalance, environmentVars>>

\* datagram/message.rs:79-81: copy failure precedes auxiliary transfer.
MessageQueueTrySendCopy ==
    /\ send.pc = "Copy" /\ queue.lock = "Sender"
    /\ send' = [send EXCEPT
         !.pc = IF send.payloadGood THEN "Enqueue" ELSE "Unlock",
         !.result = IF send.payloadGood THEN "Pending" ELSE "EFAULT"]
    /\ UNCHANGED <<queue, rx, tableVars, refBalance, environmentVars>>

\* datagram/message.rs:83-96: moving references does not change their count.
MessageQueueTrySendEnqueue ==
    /\ send.pc = "Enqueue" /\ queue.lock = "Sender"
    /\ queue' = [queue EXCEPT !.msg = Message, !.rights = send.temp,
                             !.enqueued = TRUE]
    /\ send' = [send EXCEPT !.temp = <<>>, !.pc = "Unlock", !.result = "OK"]
    /\ UNCHANGED <<rx, tableVars, refBalance, environmentVars>>

\* datagram/message.rs:81,100: the queue guard drops on both exits.
MessageQueueTrySendUnlock ==
    /\ send.pc = "Unlock" /\ queue.lock = "Sender"
    /\ queue' = [queue EXCEPT !.lock = NoOwner]
    /\ send' = [send EXCEPT !.pc = "Drop"]
    /\ UNCHANGED <<rx, tableVars, refBalance, environmentVars>>

\* ctrl_msg.rs:215-217; datagram/socket.rs:95,134-135: drop undelivered aux.
\* Each Arc release is separate; it can interleave with another owner's drop.
SendTemporaryDrop ==
    /\ send.pc = "Drop" /\ send.temp /= <<>>
    /\ refBalance' = [refBalance EXCEPT ![Head(send.temp)] = @ - 1]
    /\ send' = [send EXCEPT !.temp = Tail(@)]
    /\ UNCHANGED <<queue, rx, tableVars, environmentVars>>

\* sys_sendmsg.rs:40-42: completion includes the failed-send local drops.
SysSendmsgComplete ==
    /\ send.pc = "Drop" /\ send.temp = <<>>
    /\ send' = [send EXCEPT !.pc = "Done"]
    /\ UNCHANGED <<queue, rx, tableVars, refBalance, environmentVars>>

PreviousComplete(o) ==
    IF o[2] = 1 THEN TRUE ELSE rx[<<o[1], o[2] - 1>>].pc = "Done"
Quiescent == \A o \in Ops : rx[o].pc \in {"Idle", "Done"}

\* S2-S4 fixture: stable buffers and 0/MSG_PEEK flags before sys_recvmsg:20.
\* Attempts on a thread are sequential. Different threads may overlap.
RecvBegin(o, mode, name, good) ==
    /\ rx[o].pc = "Idle" /\ PreviousComplete(o)
    /\ send.pc = "Done" /\ ~queue.closed /\ ~cleanupRequested
    /\ mode \in {"Recv", "Peek"} /\ name \in LayoutNames /\ good \in BOOLEAN
    /\ rx' = [rx EXCEPT ![o] =
        [EmptyReceiver EXCEPT !.pc = "Lock", !.mode = mode,
          !.layout = Layout(name), !.payloadGood = good,
          !.reportedLen = Layout(name).capacity]]
    /\ UNCHANGED <<send, queue, tableVars, refBalance, environmentVars>>

\* datagram/message.rs:179: the mutex remains held through copying/generation.
MessageReceiverTryRecvLock(o) ==
    /\ rx[o].pc = "Lock" /\ queue.lock = NoOwner
    /\ queue' = [queue EXCEPT !.lock = o]
    /\ rx' = [rx EXCEPT ![o].pc = "Select"]
    /\ UNCHANGED <<send, tableVars, refBalance, environmentVars>>

\* datagram/message.rs:182-195: a borrowed selection adds no ordinary-file ref.
MessageReceiverTryRecvSelect(o) ==
    /\ rx[o].pc = "Select" /\ queue.lock = o
    /\ IF queue.msg = Message
       THEN /\ rx' = [rx EXCEPT ![o].selected = queue.msg, ![o].pc = "Copy"]
       ELSE /\ rx' = [rx EXCEPT ![o].pc = "Unlock", ![o].returnValue = "EAGAIN"]
    /\ UNCHANGED <<send, queue, tableVars, refBalance, environmentVars>>

\* datagram/message.rs:194-195; util/iovec.rs:304-320: error before dequeue.
\* S4 records membership at the fault, so a later retry cannot erase evidence.
MessageReceiverTryRecvCopy(o) ==
    /\ rx[o].pc = "Copy" /\ queue.lock = o
    /\ IF rx[o].payloadGood
       THEN /\ rx' = [rx EXCEPT ![o].payloadResult = "OK",
                       ![o].pc = IF rx[o].mode = "Recv" THEN "Dequeue"
                                ELSE "GeneratePeek"]
       ELSE /\ rx' = [rx EXCEPT ![o].payloadResult = "Fault",
                       ![o].faultRetained = (queue.msg = rx[o].selected),
                       ![o].returnValue = "EFAULT", ![o].pc = "Unlock"]
    /\ UNCHANGED <<send, queue, tableVars, refBalance, environmentVars>>

\* datagram/message.rs:202-210: the local Message owns the popped rights.
MessageReceiverTryRecvDequeue(o) ==
    /\ rx[o].pc = "Dequeue" /\ queue.lock = o
    /\ queue' = [queue EXCEPT !.msg = NoMessage, !.rights = <<>>,
                             !.consumed = @ + 1]
    /\ rx' = [rx EXCEPT ![o].selectedRef = queue.rights, ![o].pc = "GenerateRecv"]
    /\ UNCHANGED <<send, tableVars, refBalance, environmentVars>>

\* ctrl_msg.rs:304-310: mem::take moves rights out of the popped Message.
AuxiliaryDataGenerateControlRecv(o) ==
    /\ rx[o].pc = "GenerateRecv" /\ queue.lock = o
    /\ rx' = [rx EXCEPT ![o].temp = rx[o].selectedRef, ![o].selectedRef = <<>>,
               ![o].generatedObjects = rx[o].selectedRef,
               ![o].generated = TRUE, ![o].pc = "Unlock"]
    /\ UNCHANGED <<send, queue, tableVars, refBalance, environmentVars>>

\* ctrl_msg.rs:305-310: clone each Arc while the queue is locked.
\* This list clone is a locked ownership transfer. Drops of unrelated owners
\* commute with its individual increments; no Arc strong_count observer exists.
AuxiliaryDataGenerateControlPeek(o) ==
    /\ rx[o].pc = "GeneratePeek" /\ queue.lock = o
    /\ rx' = [rx EXCEPT ![o].temp = queue.rights, ![o].generated = TRUE,
               ![o].generatedObjects = queue.rights, ![o].pc = "Unlock",
               ![o].peekBefore = queue.rights, ![o].peekAfter = queue.rights,
               ![o].peekMessageBefore = queue.msg, ![o].peekMessageAfter = queue.msg]
    /\ refBalance' = [obj \in Objects |->
                        refBalance[obj] + Count(queue.rights, obj)]
    /\ UNCHANGED <<send, queue, tableVars, environmentVars>>

\* datagram/message.rs:184,195,217: release before ancillary publication.
MessageReceiverTryRecvUnlock(o) ==
    /\ rx[o].pc = "Unlock" /\ queue.lock = o
    /\ queue' = [queue EXCEPT !.lock = NoOwner]
    /\ rx' = [rx EXCEPT ![o].pc =
                  IF rx[o].payloadResult = "OK" THEN "ReleaseBorrow" ELSE "Drop"]
    /\ UNCHANGED <<send, tableVars, refBalance, environmentVars>>

\* syscall/recvmsg.rs:43-45: explicit borrow release is a separate boundary.
SysRecvmsgReleaseBorrow(o) ==
    /\ rx[o].pc = "ReleaseBorrow"
    /\ rx' = [rx EXCEPT ![o].pc = "Control"]
    /\ UNCHANGED <<send, queue, tableVars, refBalance, environmentVars>>

\* util/net/socket.rs:143-156: NULL bypasses writer/header/insertion entirely.
CUserMsgHdrWriteControl(o) ==
    /\ rx[o].pc = "Control"
    /\ IF rx[o].layout.null
       THEN /\ rx' = [rx EXCEPT ![o].controlError = "Null", ![o].ctrunc = TRUE,
                        ![o].internalLen = 0, ![o].pc = "Writeback"]
       ELSE /\ rx' = [rx EXCEPT ![o].pc = "Capacity"]
    /\ UNCHANGED <<send, queue, tableVars, refBalance, environmentVars>>

\* ctrl_msg.rs:117-134: capacity is bytes after header, not CMSG_SPACE count.
FileMessageWriteCapacity(o) ==
    /\ rx[o].pc = "Capacity"
    /\ LET n == CapacityCount(rx[o].layout)
       IN /\ rx' = [rx EXCEPT ![o].nfit = n,
                     ![o].controlError = IF n = 0 THEN "Capacity" ELSE "",
                     ![o].pc = IF n = 0 THEN "Report" ELSE "Header"]
    /\ UNCHANGED <<send, queue, tableVars, refBalance, environmentVars>>

\* ctrl_msg.rs:130-135; OSTD io/mod.rs:795-808: header first, cursor rewind
\* on error, but copied bytes persist. No FD exists from this call yet.
FileMessageWriteHeader(o) ==
    /\ rx[o].pc = "Header"
    /\ LET n == rx[o].layout.headerCopied
       IN /\ rx' = [rx EXCEPT ![o].dirtyBytes = @ \cup ByteRange(0, n),
               ![o].headerResult = IF n = HeaderBytes THEN "OK" ELSE "Fault",
               ![o].headerLen = IF n = HeaderBytes
                               THEN HeaderBytes + FDBytes * rx[o].nfit ELSE 0,
               ![o].cursor = IF n = HeaderBytes THEN HeaderBytes ELSE 0,
               ![o].controlError = IF n = HeaderBytes THEN "" ELSE "Header",
               ![o].pc = IF n = HeaderBytes THEN "Install" ELSE "Report"]
    /\ UNCHANGED <<send, queue, tableVars, refBalance, environmentVars>>

FreeFDs == {fd \in FDs : fdTable[<<ReceiverTable, fd>>] = NoObject}
NextFD == CHOOSE fd \in FreeFDs : \A other \in FreeFDs : fd <= other

\* ctrl_msg.rs:139-144; file_table.rs:190-193: one write-lock insertion.
\* kernel/libs/aster-util/src/slot_vec.rs:66-76 selects the lowest free FD.
\* The lock is gone in the successor state, before VmWriterWriteFd.
FileTableInsert(o) ==
    /\ rx[o].pc = "Install"
    /\ Assert(FreeFDs /= {}, "FD bound exhausted; allocation stress is excluded")
    /\ LET i == rx[o].index
           fd == NextFD
           s == <<ReceiverTable, fd>>
           obj == rx[o].temp[i]
       IN /\ fdTable' = [fdTable EXCEPT ![s] = obj]
          /\ fdOrigin' = [fdOrigin EXCEPT ![s] = <<o, i>>]
          /\ refBalance' = [refBalance EXCEPT ![obj] = @ + 1]
          /\ rx' = [rx EXCEPT ![o].fdForEntry[i] = fd,
                      ![o].installedObjects[i] = obj,
                      ![o].installed = @ \cup {i}, ![o].pc = "Number"]
    /\ UNCHANGED <<send, queue, closing, releasedEntries, environmentVars>>

\* ctrl_msg.rs:145-148 and OSTD io/mod.rs:795-808: preserve the insertion
\* on failure. A later fault also preserves every earlier complete integer.
VmWriterWriteFd(o) ==
    /\ rx[o].pc = "Number"
    /\ LET i == rx[o].index
           good == i /= rx[o].layout.failEntry
           n == IF good THEN FDBytes ELSE rx[o].layout.partialBytes
           offset == HeaderBytes + FDBytes * (i - 1)
       IN /\ rx' = [rx EXCEPT
             ![o].dirtyBytes = @ \cup ByteRange(offset, n),
             ![o].numberComplete = IF good THEN @ \cup {i} ELSE @,
             ![o].numberFailed = IF good THEN @ ELSE @ \cup {i},
             ![o].delivered = IF good THEN @ \cup {i} ELSE @,
             ![o].cursor = IF good THEN @ + FDBytes ELSE @,
             ![o].controlError = IF good THEN "" ELSE "Number",
             ![o].index = IF good THEN i + 1 ELSE i,
             ![o].pc = IF good /\ i < rx[o].nfit THEN "Install" ELSE "Report"]
    /\ UNCHANGED <<send, queue, tableVars, refBalance, environmentVars>>

\* util/message_header.rs:104-129: a failed cmsg contributes zero length.
\* Successful padding is skipped, not copied. These effects stay separate.
ControlMessageWriteAllTo(o) ==
    /\ rx[o].pc = "Report"
    /\ LET good == rx[o].controlError = ""
           n == IF good THEN Min(rx[o].layout.capacity, Align(rx[o].headerLen))
                ELSE 0
       IN /\ rx' = [rx EXCEPT ![o].internalLen = n,
              ![o].ctrunc = (~good \/ rx[o].nfit < RightsCount),
              ![o].cursor = IF good THEN n ELSE @, ![o].pc = "Writeback"]
    /\ UNCHANGED <<send, queue, tableVars, refBalance, environmentVars>>

\* syscall/recvmsg.rs:48-58: NULL name and writable outer msghdr are assumed.
\* Publication of length/flags is separate from integer and header copying.
SysRecvmsgWriteback(o) ==
    /\ rx[o].pc = "Writeback"
    /\ rx' = [rx EXCEPT ![o].reportedLen = rx[o].internalLen,
               ![o].reportedCtrunc = rx[o].ctrunc, ![o].msghdrWritten = TRUE,
               ![o].returnValue = PayloadSize, ![o].pc = "Drop"]
    /\ UNCHANGED <<send, queue, tableVars, refBalance, environmentVars>>

\* ctrl_msg.rs:69-71; syscall/recvmsg.rs:32-58: dropping the local header
\* releases its list, including entries also cloned into the file table.
RecvTemporaryDrop(o) ==
    /\ rx[o].pc = "Drop" /\ rx[o].temp /= <<>>
    /\ refBalance' = [refBalance EXCEPT ![Head(rx[o].temp)] = @ - 1]
    /\ rx' = [rx EXCEPT ![o].temp = Tail(@)]
    /\ UNCHANGED <<send, queue, tableVars, environmentVars>>

\* syscall/recvmsg.rs:40,58: completion follows implicit local destruction.
SysRecvmsgComplete(o) ==
    /\ rx[o].pc = "Drop" /\ rx[o].temp = <<>> /\ rx[o].selectedRef = <<>>
    /\ rx' = [rx EXCEPT ![o].pc = "Done"]
    /\ UNCHANGED <<send, queue, tableVars, refBalance, environmentVars>>

\* S1 fixture cleanup request. It forbids new calls, not in-flight completion.
\* Quiescence avoids the excluded close/receive and shutdown races.
RequestCleanup ==
    /\ ~cleanupRequested /\ send.pc = "Done" /\ Quiescent
    /\ cleanupRequested' = TRUE
    /\ UNCHANGED <<send, queue, rx, tableVars, refBalance, senderReused>>

\* syscall/close.rs:22-28; file_table.rs:196-205: remove under the table lock.
\* Only original sender closes after a successful send, or requested quiescent
\* cleanup, are allowed. Unexpected installed FDs are observed before cleanup.
FileTableCloseFile(s) ==
    /\ fdTable[s] \in Objects /\ closing[s] = NoObject
    /\ cleanupRequested \/
         (send.pc = "Done" /\ send.result = "OK" /\ fdOrigin[s] = "Sender")
    /\ closing' = [closing EXCEPT ![s] = fdTable[s]]
    /\ fdTable' = [fdTable EXCEPT ![s] = NoObject]
    /\ fdOrigin' = [fdOrigin EXCEPT ![s] = "Other"]
    /\ releasedEntries' =
         IF fdOrigin[s] \in (Ops \X Entries)
         THEN releasedEntries \cup {fdOrigin[s]} ELSE releasedEntries
    /\ UNCHANGED <<send, queue, rx, refBalance, environmentVars>>

\* syscall/close.rs:35; file_table.rs:274-297: drop outside the table lock.
ClosedFileDrop(s) ==
    /\ closing[s] \in Objects
    /\ refBalance' = [refBalance EXCEPT ![closing[s]] = @ - 1]
    /\ closing' = [closing EXCEPT ![s] = NoObject]
    /\ UNCHANGED <<send, queue, rx, fdTable, fdOrigin, releasedEntries,
                   environmentVars>>

\* S1 controlled sender reuse: syscall/dup.rs:21-34,77-82.
\* dup2(B, old-A) runs after the old A close/drop and before receive calls.
\* This is the brief's intentional sender reuse, not unrelated FD mutation.
SenderReuse ==
    /\ send.pc = "Done" /\ send.result = "OK" /\ ~senderReused
    /\ ~cleanupRequested /\ (\A o \in Ops : rx[o].pc = "Idle")
    /\ fdTable[SenderA] = NoObject /\ closing[SenderA] = NoObject
    /\ fdTable[SenderB] = ObjectB
    /\ fdTable' = [fdTable EXCEPT ![SenderA] = ObjectB]
    /\ fdOrigin' = [fdOrigin EXCEPT ![SenderA] = "Reuse"]
    /\ refBalance' = [refBalance EXCEPT ![ObjectB] = @ + 1]
    /\ senderReused' = TRUE
    /\ UNCHANGED <<send, queue, rx, closing, releasedEntries, cleanupRequested>>

\* datagram/message.rs:262-268: take the final receiver's queue under its lock.
\* Keep the old value's references explicit until its destructor releases them.
MessageReceiverDropBegin ==
    /\ cleanupRequested /\ ~queue.closed /\ queue.lock = NoOwner
    /\ queue' = [queue EXCEPT !.lock = "Disposer",
          !.disposeTemp = queue.rights, !.rights = <<>>, !.msg = NoMessage,
          !.disposed = @ + IF queue.msg = Message THEN 1 ELSE 0]
    /\ UNCHANGED <<send, rx, tableVars, refBalance, environmentVars>>

\* datagram/message.rs:268 and ctrl_msg.rs:215-217: drop each queued Arc.
MessageReceiverDropReference ==
    /\ queue.lock = "Disposer" /\ queue.disposeTemp /= <<>>
    /\ refBalance' = [refBalance EXCEPT ![Head(queue.disposeTemp)] = @ - 1]
    /\ queue' = [queue EXCEPT !.disposeTemp = Tail(@)]
    /\ UNCHANGED <<send, rx, tableVars, environmentVars>>

\* datagram/message.rs:268-270: all queued rights are gone before completion.
MessageReceiverDropComplete ==
    /\ queue.lock = "Disposer" /\ queue.disposeTemp = <<>>
    /\ queue' = [queue EXCEPT !.closed = TRUE, !.lock = NoOwner]
    /\ UNCHANGED <<send, rx, tableVars, refBalance, environmentVars>>

SendStep ==
    \/ FileMessageReadFrom \/ AuxiliaryDataFromControl
    \/ MessageQueueTrySendLock \/ MessageQueueTrySendCopy
    \/ MessageQueueTrySendEnqueue \/ MessageQueueTrySendUnlock
    \/ SendTemporaryDrop \/ SysSendmsgComplete
RecvStep(o) ==
    \/ MessageReceiverTryRecvLock(o) \/ MessageReceiverTryRecvSelect(o)
    \/ MessageReceiverTryRecvCopy(o) \/ MessageReceiverTryRecvDequeue(o)
    \/ AuxiliaryDataGenerateControlRecv(o) \/ AuxiliaryDataGenerateControlPeek(o)
    \/ MessageReceiverTryRecvUnlock(o) \/ SysRecvmsgReleaseBorrow(o)
    \/ CUserMsgHdrWriteControl(o) \/ FileMessageWriteCapacity(o)
    \/ FileMessageWriteHeader(o) \/ FileTableInsert(o) \/ VmWriterWriteFd(o)
    \/ ControlMessageWriteAllTo(o) \/ SysRecvmsgWriteback(o)
    \/ RecvTemporaryDrop(o) \/ SysRecvmsgComplete(o)
DisposeStep ==
    MessageReceiverDropBegin \/ MessageReceiverDropReference
                            \/ MessageReceiverDropComplete
ReactiveNext ==
    \/ SendStep
    \/ \E o \in Ops : RecvStep(o)
    \/ \E s \in Slots : FileTableCloseFile(s) \/ ClosedFileDrop(s)
    \/ DisposeStep
Next ==
    \/ \E good \in BOOLEAN : SendBegin(good)
    \/ \E o \in Ops, mode \in {"Recv", "Peek"}, name \in LayoutNames,
          good \in BOOLEAN : RecvBegin(o, mode, name, good)
    \/ SenderReuse \/ RequestCleanup \/ ReactiveNext

\* S1-S4: fairness only for started operations and requested cleanup.
\* Finite call slots prevent infinitely many newcomers starving a lock waiter.
OperationFairness ==
    /\ WF_vars(SendStep)
    /\ \A o \in Ops : WF_vars(RecvStep(o))
    /\ WF_vars(DisposeStep)
    /\ \A s \in Slots :
         WF_vars(cleanupRequested /\ FileTableCloseFile(s)) /\
         WF_vars(ClosedFileDrop(s))
Spec == Init /\ [][Next]_vars /\ OperationFairness

SendPCs == {"Idle", "Capture", "Lock", "Copy", "Enqueue", "Unlock", "Drop", "Done"}
RecvPCs == {"Idle", "Lock", "Select", "Copy", "Dequeue", "GenerateRecv",
            "GeneratePeek", "Unlock", "ReleaseBorrow", "Control", "Capacity",
            "Header", "Install", "Number", "Report", "Writeback", "Drop", "Done"}
ObjectSeq == UNION {[1..n -> Objects] : n \in 0..RightsCount}
ReceiverType(r) ==
    /\ DOMAIN r = DOMAIN EmptyReceiver
    /\ r.pc \in RecvPCs /\ r.mode \in {"Recv", "Peek"}
    /\ r.layout \in {Layout(n) : n \in LayoutNames}
    /\ r.payloadGood \in BOOLEAN /\ r.selected \in {NoMessage, Message}
    /\ r.payloadResult \in {"Pending", "OK", "Fault"}
    /\ r.temp \in ObjectSeq /\ r.selectedRef \in ObjectSeq
    /\ r.nfit \in 0..RightsCount /\ r.index \in 1..(RightsCount + 1)
    /\ r.fdForEntry \in [Entries -> FDs \cup {-1}]
    /\ r.installedObjects \in [Entries -> Objects \cup {NoObject}]
    /\ r.installed \subseteq Entries /\ r.numberComplete \subseteq Entries
    /\ r.numberFailed \subseteq Entries /\ r.delivered \subseteq Entries
    /\ r.dirtyBytes \subseteq 0..(HeaderBytes + FDBytes * RightsCount - 1)
    /\ r.cursor \in 0..Align(HeaderBytes + FDBytes * RightsCount)
    /\ r.headerResult \in {"Unattempted", "OK", "Fault"}
    /\ r.headerLen \in 0..(HeaderBytes + FDBytes * RightsCount)
    /\ r.controlError \in {"", "Null", "Capacity", "Header", "Number"}
    /\ r.internalLen \in 0..Align(HeaderBytes + FDBytes * RightsCount)
    /\ r.reportedLen \in 0..Align(HeaderBytes + FDBytes * RightsCount)
    /\ r.ctrunc \in BOOLEAN /\ r.reportedCtrunc \in BOOLEAN
    /\ r.msghdrWritten \in BOOLEAN
    /\ r.returnValue \in {"Pending", "EFAULT", "EAGAIN", PayloadSize}
    /\ r.faultRetained \in BOOLEAN /\ r.generated \in BOOLEAN
    /\ r.peekBefore \in ObjectSeq /\ r.peekAfter \in ObjectSeq
    /\ r.generatedObjects \in ObjectSeq
    /\ r.peekMessageBefore \in {NoMessage, Message}
    /\ r.peekMessageAfter \in {NoMessage, Message}

\* Brief section 5 safety properties. Identities are typed separately from FDs.
TypeOK ==
    /\ ObjectA /= ObjectB
    /\ Objects \cap (FDs \cup Slots \cup
         {NoObject, "External", NoMessage, Message, NoOwner, "Sender", "Disposer"}) = {}
    /\ Threads /= {} /\ AttemptSlots \in Nat \ {0}
    /\ RightsCount \in 1..4 /\ SetupFDCount \in Nat /\ PayloadSize > 0
    /\ SharedTable \in BOOLEAN /\ MaxFD >= SetupFDCount + 1 + 16
    /\ send.pc \in SendPCs /\ send.temp \in ObjectSeq
    /\ send.capturedObjects \in ObjectSeq /\ send.payloadGood \in BOOLEAN
    /\ send.result \in {"Pending", "OK", "EFAULT"}
    /\ queue.msg \in {NoMessage, Message}
    /\ queue.rights \in ObjectSeq /\ queue.disposeTemp \in ObjectSeq
    /\ queue.lock \in Ops \cup {NoOwner, "Sender", "Disposer"}
    /\ queue.enqueued \in BOOLEAN /\ queue.closed \in BOOLEAN
    /\ queue.consumed \in Nat /\ queue.disposed \in Nat
    /\ DOMAIN rx = Ops /\ (\A o \in Ops : ReceiverType(rx[o]))
    /\ fdTable \in [Slots -> Objects \cup {NoObject, "External"}]
    /\ fdOrigin \in [Slots -> {"Sender", "Reuse", "Other"} \cup (Ops \X Entries)]
    /\ closing \in [Slots -> Objects \cup {NoObject}]
    /\ refBalance \in [Objects -> Int]
    /\ releasedEntries \subseteq (Ops \X Entries)
    /\ cleanupRequested \in BOOLEAN /\ senderReused \in BOOLEAN

OwnerCount(obj) ==
    Cardinality({s \in Slots : fdTable[s] = obj}) +
    Cardinality({s \in Slots : closing[s] = obj}) +
    Count(send.temp, obj) + Count(queue.rights, obj) +
    Count(queue.disposeTemp, obj) +
    Cardinality({p \in Ops \X Entries :
       IF p[2] \in DOMAIN rx[p[1]].temp
       THEN rx[p[1]].temp[p[2]] = obj ELSE FALSE}) +
    Cardinality({p \in Ops \X Entries :
       IF p[2] \in DOMAIN rx[p[1]].selectedRef
       THEN rx[p[1]].selectedRef[p[2]] = obj ELSE FALSE})

\* refBalance changes only at source clone/drop sites; it is not recomputed
\* from owner locations. In particular, every move must conserve the balance.
OwnershipConserved == \A obj \in Objects :
    refBalance[obj] = OwnerCount(obj) /\ refBalance[obj] >= 0
CapturedObjectIdentity ==
    /\ send.capturedObjects = SubSeq(ExpectedObjects, 1, Len(send.capturedObjects))
    /\ \A o \in Ops :
         /\ rx[o].generated => rx[o].generatedObjects = send.capturedObjects
         /\ \A i \in rx[o].installed :
              rx[o].installedObjects[i] = send.capturedObjects[i]
OrdinaryConsumeAtMostOnce == queue.consumed <= 1
PeekPreservesQueueRights ==
    \A o \in Ops : (rx[o].mode = "Peek" /\ rx[o].generated) =>
        /\ rx[o].peekMessageBefore = Message
        /\ rx[o].peekMessageAfter = rx[o].peekMessageBefore
        /\ rx[o].peekBefore = rx[o].peekAfter
        /\ rx[o].generatedObjects = rx[o].peekBefore
DeliveredPrefixSurvives ==
    \A o \in Ops : \A i \in rx[o].delivered :
       /\ i \in rx[o].numberComplete \cap rx[o].installed
       /\ <<o, i>> \notin releasedEntries =>
            /\ fdTable[<<ReceiverTable, rx[o].fdForEntry[i]>>] =
                 rx[o].installedObjects[i]
            /\ fdOrigin[<<ReceiverTable, rx[o].fdForEntry[i]>>] = <<o, i>>
OperationOwnersDrained ==
    /\ (send.pc = "Done" => send.temp = <<>>)
    /\ \A o \in Ops : rx[o].pc = "Done" =>
         (rx[o].temp = <<>> /\ rx[o].selectedRef = <<>>)

\* Linux fs/file.c:1364-1376: failed reservation is freed, successful earlier
\* entries survive. Check at completion, not the legitimate insert/copy window.
NoFailedNumberInstalled ==
    \A o \in Ops : rx[o].pc = "Done" =>
        rx[o].installed \cap rx[o].numberFailed = {}

\* Linux net/core/scm.c:348-378: report only a delivered prefix after a fault.
\* The zero-delivery case has no header. Header faults are deliberately outside
\* this predicate because Linux can retain FDs despite failing header output.
ReportedPrefixMatchesLinux ==
    \A o \in Ops :
      (rx[o].pc = "Done" /\ rx[o].numberFailed /= {} /\
       rx[o].layout.headerCopied = HeaderBytes) =>
        LET n == Cardinality(rx[o].delivered)
        IN /\ rx[o].reportedCtrunc
           /\ rx[o].reportedLen =
                IF n = 0 THEN 0
                ELSE Min(rx[o].layout.capacity, Align(HeaderBytes + FDBytes * n))
           /\ (n > 0 => rx[o].headerLen = HeaderBytes + FDBytes * n)

\* Linux net/core/datagram.c:183-202; net/unix/af_unix.c:2558-2600.
\* The saved fault-time membership prevents a later consume masking AST-36.
PayloadFaultConsumptionMatchesLinux ==
    \A o \in Ops : (rx[o].pc = "Done" /\ rx[o].payloadResult = "Fault") =>
        (rx[o].faultRetained = (rx[o].mode = "Peek"))

\* Structural checks for convergence, independent of Linux compatibility.
QueueStructure ==
    /\ ((queue.msg = Message) = (queue.rights /= <<>>))
    /\ (queue.msg = Message => queue.rights = send.capturedObjects)
    /\ (IF queue.enqueued THEN 1 ELSE 0) =
         (IF queue.msg = Message THEN 1 ELSE 0) + queue.consumed + queue.disposed
    /\ (queue.closed => queue.rights = <<>> /\ queue.disposeTemp = <<>>)
PublicationStructure ==
    \A o \in Ops :
      /\ rx[o].numberComplete \subseteq rx[o].installed
      /\ rx[o].delivered = rx[o].numberComplete \cap rx[o].installed
      /\ rx[o].numberComplete \cap rx[o].numberFailed = {}
      /\ rx[o].numberComplete = 1..Cardinality(rx[o].numberComplete)
      /\ (rx[o].installed /= {} => rx[o].headerResult = "OK")
      /\ rx[o].msghdrWritten => rx[o].returnValue = PayloadSize
AllReleased ==
    /\ queue.closed
    /\ \A s \in Slots : fdTable[s] \notin Objects /\ closing[s] = NoObject
    /\ \A obj \in Objects : refBalance[obj] = 0
BoundedCleanupProgress ==
    /\ (send.pc \notin {"Idle", "Done"} ~> send.pc = "Done")
    /\ \A o \in Ops : (rx[o].pc \notin {"Idle", "Done"} ~> rx[o].pc = "Done")
    /\ (cleanupRequested ~> AllReleased)
====
