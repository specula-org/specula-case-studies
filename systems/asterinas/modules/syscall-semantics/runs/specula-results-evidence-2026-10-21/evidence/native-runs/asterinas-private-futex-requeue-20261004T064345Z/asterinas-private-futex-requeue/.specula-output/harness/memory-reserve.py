"""Wait for the policy's host-visible reserve immediately before a kernel build."""
import pathlib,sys,time
end=time.monotonic()+1200
while True:
    m={l.split(':')[0]:int(l.split()[1]) for l in pathlib.Path('/proc/meminfo').read_text().splitlines()}
    print(f'Memory reserve: total={m["MemTotal"]} KiB available={m["MemAvailable"]} KiB',flush=True)
    if m['MemAvailable']>=10*1024*1024:break
    if time.monotonic()>=end:sys.exit('The kernel build reserve was unavailable during the bounded wait.')
    time.sleep(20)
