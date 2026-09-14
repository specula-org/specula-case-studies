from pathlib import Path
D=Path(__file__).resolve().parent
p=D/'build_base.py'
s=p.read_text()
if '# Preserve caller-side wf_lock' not in s:
 s=s.replace('# Emit disjunction;', (D/'boundaries.py.inc').read_text()+'\n# Emit disjunction;')
 p.write_text(s)
