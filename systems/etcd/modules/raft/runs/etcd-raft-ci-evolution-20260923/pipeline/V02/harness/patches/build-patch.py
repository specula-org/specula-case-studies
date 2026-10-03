"""Create the observational patch once from the supplied incremental source.

Not invoked by apply.sh; retained to make the hook placement reviewable.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[3] / 'source'
p = root / 'raft.go'
s = p.read_text()
def replace(old, new, count=1):
    global s
    assert s.count(old) == count, (old, s.count(old), count)
    s = s.replace(old, new)
replace('\tr.msgs = append(r.msgs, m)', '\tspeculaObserve("send", r, m, nil)\n\tr.msgs = append(r.msgs, m)')
replace('func (r *raft) reset(term uint64) {', 'func (r *raft) reset(term uint64) {\n\tdefer speculaObserve("reset", r, pb.Message{}, nil)')
replace('\tr.prs.Progress[r.id].MaybeUpdate(li)', '\tr.prs.Progress[r.id].MaybeUpdate(li)\n\tspeculaObserve("self-append", r, pb.Message{}, nil)')
replace('\t\t\tif pr.MaybeUpdate(m.Index) {', '\t\t\tif pr.MaybeUpdate(m.Index) {\n\t\t\t\tspeculaObserve("match", r, m, nil)')
replace('\t\t\t\tr.readOnly.recvAck(r.id, m.Entries[0].Data)', '\t\t\t\tr.readOnly.recvAck(r.id, m.Entries[0].Data)\n\t\t\t\tspeculaObserve("read-add", r, m, nil)')
replace('\t\t} else { // only one voting member (the leader) in the cluster', '\t\t} else { // only one voting member (the leader) in the cluster\n\t\t\tspeculaObserve("read-singleton", r, m, nil)')
replace('\t\trss := r.readOnly.advance(m)', '\t\tspeculaObserve("read-confirm", r, m, nil)\n\t\trss := r.readOnly.advance(m)\n\t\tspeculaObserve("read-release", r, m, rss)')
replace('\tr.logger.Infof("%x [commit: %d, lastindex: %d, lastterm: %d] restored snapshot', '\tspeculaObserve("restore", r, pb.Message{Snapshot: s}, nil)\n\tr.logger.Infof("%x [commit: %d, lastindex: %d, lastterm: %d] restored snapshot')
replace('\t\t\t// drop any new proposals.\n\t\t\treturn ErrProposalDropped', '\t\t\t// drop any new proposals.\n\t\t\tspeculaObserve("DropRemoved", r, m, nil)\n\t\t\treturn ErrProposalDropped')
replace('\t\t\tr.logger.Debugf("%x [term %d] transfer leadership to %x is in progress; dropping proposal", r.id, r.Term, r.leadTransferee)', '\t\t\tspeculaObserve("DropTransfer", r, m, nil)\n\t\t\tr.logger.Debugf("%x [term %d] transfer leadership to %x is in progress; dropping proposal", r.id, r.Term, r.leadTransferee)')
replace('\t\tif !r.appendEntry(m.Entries...) {\n\t\t\treturn ErrProposalDropped\n\t\t}', '\t\tif !r.appendEntry(m.Entries...) {\n\t\t\tspeculaObserve("DropQuota", r, m, nil)\n\t\t\treturn ErrProposalDropped\n\t\t}\n\t\tspeculaObserve("Accepted", r, m, nil)')
replace('\n\t\tr.logger.Infof("%x no leader at term %d; dropping proposal", r.id, r.Term)', '\n\t\tspeculaObserve("DropNoLeader", r, m, nil)\n\t\tr.logger.Infof("%x no leader at term %d; dropping proposal", r.id, r.Term)')
replace('\t\t\tr.logger.Infof("%x no leader at term %d; dropping proposal", r.id, r.Term)', '\t\t\tspeculaObserve("DropNoLeader", r, m, nil)\n\t\t\tr.logger.Infof("%x no leader at term %d; dropping proposal", r.id, r.Term)')
replace('\t\t\tr.logger.Infof("%x not forwarding to leader %x at term %d; dropping proposal", r.id, r.lead, r.Term)', '\t\t\tspeculaObserve("DropForwardDisabled", r, m, nil)\n\t\t\tr.logger.Infof("%x not forwarding to leader %x at term %d; dropping proposal", r.id, r.lead, r.Term)')
# Inserting after the follower proposal guard, not the read/transfer forwarding branches.
replace('\t\tm.To = r.lead\n\t\tr.send(m)\n\tcase pb.MsgApp:', '\t\tspeculaObserve("Forwarded", r, m, nil)\n\t\tm.To = r.lead\n\t\tr.send(m)\n\tcase pb.MsgApp:')
p.write_text(s)
p = root / 'node.go'
s = p.read_text()
replace('\n\t\tselect {\n\t\t// TODO: maybe buffer', '\n\t\tspeculaNodeLoop(r, n.rn.prevHardSt, n.rn.prevSoftSt, lead, propc != nil)\n\t\tselect {\n\t\t// TODO: maybe buffer')
p.write_text(s)
