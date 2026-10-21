#!/usr/bin/env python3
"""Apply exact source transformations to the exported Specula baseline."""
from pathlib import Path
import hashlib, json, subprocess, shutil
H = Path(__file__).resolve().parents[1]
S = H.parents[1] / 'source'
BASE = H.parents[1] / 'baseline.git'
changes = {}
def original(path):
    if path not in changes:
        changes[path] = subprocess.check_output(['git', '--git-dir='+str(BASE), 'show', 'refs/specula/baseline:'+path]).decode()
    return changes[path]
def edit(path, old, new, count=1):
    value=original(path)
    if value.count(old)!=count: raise RuntimeError(f'{path}: expected {count}, got {value.count(old)}: {old[:100]}')
    changes[path]=value.replace(old,new)
def scope(path, begin, finish, transform):
    value=original(path); lo=value.index(begin); hi=value.index(finish,lo)
    changes[path]=value[:lo]+transform(value[lo:hi])+value[hi:]
def wrap(path, begin, finish, isunit=False):
    def f(code):
        brace=code.index('{'); end=code.rfind('}')
        expr='result.as_ref().map(|_| 0).map_err(Clone::clone)' if isunit else 'result'
        return code[:brace+1]+'\n        let result = (|| {'+code[brace+1:end]+'\n        })();\n        let specula_start = crate::tla_trace::stamp();\n        crate::tla_trace::returned("BackendReturn", specula_start, &'+expr+', 0);\n        result\n    '+code[end:]
    scope(path,begin,finish,f)
R='kernel/core/src/'
edit(R+'lib.rs','mod thread;','mod thread;\npub(crate) mod tla_trace;')
p=R+'process/posix_thread/thread_local.rs'
edit(p,'pub(crate) struct ThreadLocal {','pub(crate) struct ThreadLocal {\n    pub(crate) specula_trace: RefCell<crate::tla_trace::Recorder>,')
edit(p,'            set_child_tid: Cell::new(set_child_tid),','            specula_trace: RefCell::new(crate::tla_trace::Recorder::new()),\n            set_child_tid: Cell::new(set_child_tid),')
p=R+'syscall/prctl.rs'
edit(p,'    let prctl_cmd = PrctlCmd::from_args(option, arg2, arg3, arg4, arg5)?;','''    if option == 0x53504543 || option == 0x53504544 {
        return crate::tla_trace::control(option, arg2 as usize, arg3 as usize, arg4 as usize)
            .map(|n| SyscallReturn::Return(n as _));
    }
    let prctl_cmd = PrctlCmd::from_args(option, arg2, arg3, arg4, arg5)?;''')
p=R+'fs/file/inode_handle.rs'
edit(p,'''        let mut offset = self.offset.lock();

        let len = file_ops.read_at(*offset, writer, status_flags)?;
        *offset += len;

        Ok(len)''','''        let specula_start = crate::tla_trace::stamp();
        let mut offset = self.offset.lock();
        crate::tla_trace::enter(specula_start, 0, *offset, writer.avail(), 0);
        let result = file_ops.read_at(*offset, writer, status_flags);
        let specula_start = crate::tla_trace::stamp();
        if let Ok(len) = result { *offset += len; }
        let specula_position = *offset;
        drop(offset);
        crate::tla_trace::returned("InodeHandleReturn", specula_start, &result, specula_position);
        result''')
edit(p,'        file_ops.read_at(offset, writer, status_flags)\n','''        let specula_start = crate::tla_trace::stamp();
        crate::tla_trace::enter(specula_start, 1, offset, writer.avail(), 0);
        let result = file_ops.read_at(offset, writer, status_flags);
        let specula_start = crate::tla_trace::stamp();
        crate::tla_trace::returned("InodeHandleReturn", specula_start, &result, 0);
        result
''')
edit(p,'        file_ops.write_at(offset, reader, status_flags)\n','''        let specula_start = crate::tla_trace::stamp();
        crate::tla_trace::enter(specula_start, 2, offset, reader.remain(), 0);
        let result = file_ops.write_at(offset, reader, status_flags);
        let specula_start = crate::tla_trace::stamp();
        crate::tla_trace::returned("InodeHandleReturn", specula_start, &result, 0);
        result
''')
p=R+'syscall/truncate.rs'
edit(p,'    file.resize(len as usize)?;','''    let specula_start = crate::tla_trace::stamp();
    crate::tla_trace::enter(specula_start, 3, 0, 0, len as usize);
    let result = file.resize(len as usize).map(|_| 0);
    let specula_start = crate::tla_trace::stamp();
    crate::tla_trace::returned("InodeHandleReturn", specula_start, &result, 0);
    result?;''')
p=R+'fs/fs_impls/ramfs/fs.rs'
edit(p,'''                let (offset, read_len) = {
                    let file_size = self.size();''','''                let specula_start = crate::tla_trace::stamp();
                let (offset, read_len, specula_size) = {
                    let file_size = self.size();''')
edit(p,'''                    (start, end - start)
                };
                page_cache.lock().read(offset, writer)?;''','''                    (start, end - start, file_size)
                };
                crate::tla_trace::event("RamfsReadAtObserve", specula_start, [specula_size, offset, read_len, 0, 0, 0, 0, 0]);
                let specula_start = crate::tla_trace::stamp();
                let cache = page_cache.lock();
                crate::tla_trace::event("RamfsReadAtAcquireCache", specula_start, [offset, writer.avail(), 0, 0, 0, 0, 0, 0]);
                cache.read(offset, writer)?;''')
edit(p,'''                let mut page_cache = self.inner.as_file().unwrap().lock();

                let mut inode_meta''','''                let specula_start = crate::tla_trace::stamp();
                let mut page_cache = self.inner.as_file().unwrap().lock();
                crate::tla_trace::event("RamfsWriteAtAcquireCache", specula_start, [0; 8]);
                let specula_start = crate::tla_trace::stamp();
                let mut inode_meta''')
edit(p,'''                drop(inode_meta);

                if should_expand_size''','''                let specula_size = inode_meta.size;
                drop(inode_meta);
                crate::tla_trace::event("RamfsWriteAtPublish", specula_start, [specula_size, file_size, new_size, new_size_aligned, 0, 0, 0, 0]);

                if should_expand_size''')
edit(p,'                page_cache.write(offset, reader)?;','''                let specula_start = crate::tla_trace::stamp();
                crate::tla_trace::event("WriteAtCopyStart", specula_start, [offset, reader.remain(), 0, 0, 0, 0, 0, 0]);
                page_cache.write(offset, reader)?;''')
# Keep the original metadata/cache order in both resize branches.
edit(p,'''        let mut page_cache = self.inner.as_file().unwrap().lock();
        let mut inode_meta''','''        let specula_start = crate::tla_trace::stamp();
        let mut page_cache = self.inner.as_file().unwrap().lock();
        crate::tla_trace::event("RamfsResizeAcquireCache", specula_start, [0; 8]);
        let specula_start = crate::tla_trace::stamp();
        let mut inode_meta''')
edit(p,'''        if file_size == new_size {
            return Ok(());
        }''','''        if file_size == new_size {
            crate::tla_trace::event("RamfsResize", specula_start, [file_size, new_size, inode_meta.size, 0, 0, 0, 0, 0]);
            return Ok(());
        }''')
edit(p,'''            inode_meta.resize(new_size);
            drop(inode_meta);
            page_cache.resize(new_size, file_size)?;''','''            inode_meta.resize(new_size);
            let specula_size = inode_meta.size;
            drop(inode_meta);
            crate::tla_trace::event("RamfsResize", specula_start, [file_size, new_size, specula_size, 0, 0, 0, 0, 0]);
            page_cache.resize(new_size, file_size)?;''')
edit(p,'''            drop(inode_meta);
            page_cache.resize(new_size, file_size)?;
            self.metadata.lock().resize(new_size);''','''            let specula_size = inode_meta.size;
            drop(inode_meta);
            crate::tla_trace::event("RamfsResize", specula_start, [file_size, new_size, specula_size, 0, 0, 0, 0, 0]);
            page_cache.resize(new_size, file_size)?;
            let specula_start = crate::tla_trace::stamp();
            let mut metadata = self.metadata.lock();
            metadata.resize(new_size);
            crate::tla_trace::event("RamfsResizePublish", specula_start, [metadata.size, 0, 0, 0, 0, 0, 0, 0]);''')
wrap(p,'    fn read_at(','    fn write_at(')
wrap(p,'    fn write_at(','    fn readdir_at(')
wrap(p,'    fn resize(&self, new_size: usize)','    fn atime(', True)

# Bind the subject before its first cache operation.
edit(p, '                let cache = page_cache.lock();', '                let cache = page_cache.lock();\n                crate::tla_trace::bind_vmo(cache.as_vmo().as_ref() as *const _ as usize);')
edit(p, '                let mut page_cache = self.inner.as_file().unwrap().lock();', '                let mut page_cache = self.inner.as_file().unwrap().lock();\n                crate::tla_trace::bind_vmo(page_cache.as_vmo().as_ref() as *const _ as usize);')
edit(p, '\n        let mut page_cache = self.inner.as_file().unwrap().lock();', '\n        let mut page_cache = self.inner.as_file().unwrap().lock();\n        crate::tla_trace::bind_vmo(page_cache.as_vmo().as_ref() as *const _ as usize);', count=1)
# Additional backend and VMO transformations are maintained beside this file.
exec((H/'src/patch_vmo.py').read_text())
exec((H/'src/patch_backends.py').read_text())
manifest={}
for path,new in changes.items():
    old=subprocess.check_output(['git','--git-dir='+str(BASE),'show','refs/specula/baseline:'+path])
    current=(S/path).read_bytes()
    previous=H/'applied'/path
    allowed=[old,new.encode()]
    if previous.exists(): allowed.append(previous.read_bytes())
    if current not in allowed: raise RuntimeError('unowned source edit: '+path)
    manifest[path]={'before_sha256':hashlib.sha256(old).hexdigest(),'after_sha256':hashlib.sha256(new.encode()).hexdigest()}
for path,new in changes.items():
    if (S/path).read_text()!=new: (S/path).write_text(new)
    previous=H/'applied'/path; previous.parent.mkdir(parents=True,exist_ok=True); previous.write_text(new)
module_path=R+'tla_trace.rs'
module=(H/'src/tla_trace.rs').read_bytes()
previous=(H/'applied'/module_path)
if (S/module_path).exists() and (S/module_path).read_bytes() not in [module,previous.read_bytes()]:
    raise RuntimeError('unowned trace module edit')
if not (S/module_path).exists() or (S/module_path).read_bytes()!=module: (S/module_path).write_bytes(module)
previous.parent.mkdir(parents=True,exist_ok=True); previous.write_bytes(module)
manifest[module_path]={'before_sha256':None,'after_sha256':hashlib.sha256(module).hexdigest()}
(H/'patches/manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(f'Applied {len(changes)} source files and the trace module')
