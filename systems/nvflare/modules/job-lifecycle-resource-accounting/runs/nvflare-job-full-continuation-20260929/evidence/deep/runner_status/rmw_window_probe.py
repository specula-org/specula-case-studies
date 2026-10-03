"""Observation-only probe: how long is the unlocked read->replace window inside FilesystemStorage.update_meta?
Times real FilesystemStorage.update_meta(replace=False) calls on a real job object (temp dir on this host)."""
import os, statistics, tempfile, time
import nvflare
from nvflare.app_common.storages.filesystem_storage import FilesystemStorage
import nvflare.app_common.storages.filesystem_storage as fss
assert "/full/source/" in nvflare.__file__
root = tempfile.mkdtemp(prefix="rmw-probe-")
st = FilesystemStorage(root_dir=root, uri_root="/")
uri = os.path.join(root, "jobs", "j1")
meta = {"status": "SUBMITTED", "schedule_history": [f"2026-09-25 10:00:{i:02d}: not enough resource" for i in range(20)]}
st.create_object(uri, b"x" * 1000, meta, overwrite_existing=False)
windows = []
real_get_meta = st.get_meta
real_write = fss._write
mark = {}
def get_meta_t(u):
    m = real_get_meta(u)
    mark["read_done"] = time.perf_counter()
    return m
def write_t(path, content, mv_file=True):
    real_write(path, content, mv_file)
    if path.endswith("meta") and "read_done" in mark:
        windows.append(time.perf_counter() - mark.pop("read_done"))
st.get_meta = get_meta_t
fss._write = write_t
for i in range(200):
    st.update_meta(uri, {"schedule_count": i}, replace=False)
fss._write = real_write
w = sorted(windows)
print(f"n={len(w)} read->replace window: median={statistics.median(w)*1000:.3f} ms p90={w[int(0.9*len(w))]*1000:.3f} ms max={w[-1]*1000:.3f} ms")
print("tmp fs:", os.statvfs(root).f_bsize, root)
