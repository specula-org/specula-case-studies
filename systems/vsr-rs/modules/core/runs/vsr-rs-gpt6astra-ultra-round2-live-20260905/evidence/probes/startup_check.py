"""Start the unmodified pinned kvstore executable on loopback in temporary dirs.
No simulator, faults to shared data, or external network endpoints.
"""
from pathlib import Path
import json, socket, subprocess, tempfile, time
root = Path(__file__).resolve().parent
binary = root / 'target/debug/pinned-kvstore'
results = []
for label, contents, expected in [('malformed', b'not-a-view\n', b'0\n'), ('invalid_utf8_read_error', b'\xff\xfe\n', b'0\n'), ('valid_control', b'9\n', b'9\n')]:
    with tempfile.TemporaryDirectory(prefix='vsr-startup-') as tmp:
        sockets=[]
        for _ in range(4):
            s=socket.socket(); s.bind(('127.0.0.1', 0)); sockets.append(s)
        ports=[s.getsockname()[1] for s in sockets]
        for s in sockets: s.close()
        view=Path(tmp)/'kvstore-node-0.view'; view.write_bytes(contents)
        argv=[str(binary), '--id','0','--replicas',','.join(f'127.0.0.1:{p}' for p in ports[:3]),'--listen',f'127.0.0.1:{ports[3]}']
        proc=subprocess.Popen(argv,cwd=tmp,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            deadline=time.monotonic()+3
            while time.monotonic()<deadline:
                if proc.poll() is not None: break
                try:
                    with socket.create_connection(('127.0.0.1',ports[3]),timeout=.05): pass
                    if view.read_bytes()==expected: break
                except (OSError, FileNotFoundError): pass
                time.sleep(.01)
            assert proc.poll() is None, f'{label}: startup exited'
            assert view.read_bytes()==expected, (label,view.read_bytes())
        finally:
            proc.terminate()
            try: stdout,stderr=proc.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill(); stdout,stderr=proc.communicate()
        assert ('recovering from view 9' in stdout) == (label=='valid_control'), (label,stdout,stderr)
        assert 'node 0 of 3:' in stdout, (label,stdout,stderr)
        results.append({'case':label,'initial_hex':contents.hex(),'final_hex':view.read_bytes().hex(),'stdout':stdout,'stderr':stderr})
print(json.dumps(results,indent=2))
