from pathlib import Path
p=Path(__file__).resolve().parent.parent/'Trace.tla'
s=p.read_text().split("TraceRecoveringDrop(e) ==",1)[0]
recv=['RecoveringDrop','OnRequest','OnPrepareRejected','OnPrepareGap','OnPrepareAppend','OnPrepareDuplicate','OnPrepareOk','OnCommit','OnGetState','OnNewStateTransfer','OnNewStateCatchUp','OnNewStateIgnored','OnStartViewChange','OnDoViewChange','OnStartView','OnRecovery','OnRecoveryResponse']
node=['OnIdle','PersistView','PublishOutput','Crash','Recover']
frame=['RunSenderBeginPartial','RunSenderComplete','RunPeerAcceptorEOF','RunPeerAcceptorReadError']
args={**{x:'e.node,e.message,e.keep' for x in recv},**{x:'e.node' for x in node},**{x:'e.frame' for x in frame},'LoseMessage':'e.message','DiscardUnavailable':'e.message','ClientOnRequest':'e.client,e.op','ClientOnIdle':'e.client','ClientOnReply':'e.message,e.keep','Stabilize':'SeqSet(e.healthy)'}
for action,arg in args.items():
 s+=f'Trace{action}(e) ==\n /\\ IsEvent(e,"{action}") /\\ {action}({arg}) /\\ Advance(e)\n'
s+='''
TraceInit ==
 /\\ Len(TraceLog)>=1 /\\ TraceLog[1].event="Init"
 /\\ Metadata.revision="3ac0104a567092139534c9022205d02281a2da41"
 /\\ Init /\\ ModelSnapshot=NormSnapshot(TraceLog[1].post) /\\ l=2
TraceNext ==
 \\/ /\\ l<=Len(TraceLog)
    /\\ LET e == TraceLog[l] IN
'''
s+='\n'.join('        '+('\\/ ' if i else '\\/ ')+f'Trace{x}(e)' for i,x in enumerate(args))
s+='''
 \\/ /\\ l>Len(TraceLog) /\\ UNCHANGED tracevars
\\* No silent actions: every owner, transport, timer and crash boundary can
\\* be instrumented. Missing events must fail instead of being invented.
TraceSpec == TraceInit /\\ [][TraceNext]_tracevars /\\ WF_tracevars(TraceNext)
TraceMatched == <> (l>Len(TraceLog))
=============================================================================
'''
p.write_text(s)
