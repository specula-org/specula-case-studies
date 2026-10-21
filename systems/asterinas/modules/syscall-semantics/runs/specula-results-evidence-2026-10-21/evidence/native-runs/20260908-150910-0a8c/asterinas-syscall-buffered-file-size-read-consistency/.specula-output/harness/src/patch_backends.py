p=R+'fs/fs_impls/exfat/inode.rs'
# Preserve the upgrade and the separate release/reacquisition window.
def read(code):
 code=code.replace('        let inner = self.inner.upread();','        let specula_start = crate::tla_trace::stamp();\n        let inner = self.inner.upread();',1)
 code=code.replace('        inner.page_cache.read(read_off, writer)?;','        crate::tla_trace::event("ExfatReadAt", specula_start, [inner.size, read_off, read_len, writer.avail(), 0, 0, 0, 0]);\n        inner.page_cache.read(read_off, writer)?;')
 return code
scope(p,'    fn read_at(&self, offset: usize','    // The offset and the length',read)
wrap(p,'    fn read_at(&self, offset: usize','    // The offset and the length')
def write(code):
 code=code.replace('        let new_size = {','        let specula_start = crate::tla_trace::stamp();\n        let new_size = {',1)
 code=code.replace('            let fs = inner.fs();','            crate::tla_trace::event("ExfatWriteAtPrepare", specula_start, [file_size, new_size.max(file_size), new_size, file_allocated_size, 0, 0, 0, 0]);\n            let fs = inner.fs();',1)
 code=code.replace('        // Locks released here,','        crate::tla_trace::event("ExfatWriteAtReleasePreparation", crate::tla_trace::last_end(), [0; 8]);\n        let specula_start = crate::tla_trace::stamp();\n        // Locks released here,')
 code=code.replace('        inner.page_cache.write(offset, reader)?;','        crate::tla_trace::event("ExfatWriteAtAcquireCopy", specula_start, [0; 8]);\n        crate::tla_trace::event("WriteAtCopyStart", crate::tla_trace::stamp(), [offset, reader.remain(), 0, 0, 0, 0, 0, 0]);\n        inner.page_cache.write(offset, reader)?;')
 code=code.replace('            let mut inner = inner.upgrade();','            let specula_start = crate::tla_trace::stamp();\n            let mut inner = inner.upgrade();')
 code=code.replace('            inner.size = new_size;','            inner.size = new_size;\n            crate::tla_trace::event("ExfatWriteAtPublish", specula_start, [inner.size, 0, 0, 0, 0, 0, 0, 0]);')
 return code
scope(p,'    fn write_at(&self, offset: usize','    fn write_direct_at(',write)
wrap(p,'    fn write_at(&self, offset: usize','    fn write_direct_at(')
edit(p,'''    fn resize(&mut self, new_size: usize, fs_guard: &MutexGuard<()>) -> Result<()> {
        let fs''','''    fn resize(&mut self, new_size: usize, fs_guard: &MutexGuard<()>) -> Result<()> {
        let specula_start = crate::tla_trace::stamp();
        let fs''')
edit(p,'''        self.size_allocated = new_size;

        Ok(())''','''        self.size_allocated = new_size;
        crate::tla_trace::event("ExfatResizeAllocation", specula_start, [self.size, self.size_allocated, self.num_clusters() as usize, 0, 0, 0, 0, 0]);

        Ok(())''')
def resize(code):
 code=code.replace('        let inner = self.inner.upread();','        let specula_start = crate::tla_trace::stamp();\n        let inner = self.inner.upread();')
 code=code.replace('        let file_size = inner.size;','        let file_size = inner.size;\n        crate::tla_trace::event("ExfatResize", specula_start, [file_size, new_size, 0, 0, 0, 0, 0, 0]);')
 code=code.replace('        let mut inner = inner.upgrade();','        let specula_start = crate::tla_trace::stamp();\n        let mut inner = inner.upgrade();\n        crate::tla_trace::event("ExfatResizeUpgrade", specula_start, [0; 8]);')
 return code
scope(p,'    fn resize(&self, new_size: usize)','    fn metadata(',resize)
wrap(p,'    fn resize(&self, new_size: usize)','    fn metadata(',True)
# Nested lock blocking needs an OSTD receipt; leave it as an explicit coverage gap.

p=R+'fs/fs_impls/ext2/inode/file.rs'
def outer_read(code):
 code=code.replace('            return Ok(0);','            crate::tla_trace::event("Ext2ReadAtEmpty", crate::tla_trace::stamp(), [0; 8]);\n            let result = Ok(0);\n            crate::tla_trace::returned("BackendReturn", crate::tla_trace::last_end(), &result, 0);\n            return result;',1)
 code=code.replace('        let read_len = self.inner.read().read_at(offset, writer)?;','        let specula_start = crate::tla_trace::stamp();\n        let inner = self.inner.read();\n        crate::tla_trace::set_start(specula_start);\n        let result = inner.read_at(offset, writer);\n        drop(inner);\n        crate::tla_trace::returned("BackendReturn", crate::tla_trace::last_end(), &result, 0);\n        let read_len = result?;')
 code=code.replace('            self.inner.write().set_atime(utils::now());','            let specula_start = crate::tla_trace::stamp();\n            self.inner.write().set_atime(utils::now());\n            crate::tla_trace::event("Ext2ReadAtUpdateAtime", specula_start, [0; 8]);')
 return code
scope(p,'    pub(in ext2) fn read_at(','    /// Writes file data',outer_read)
def inner_read(code):
 code=code.replace('        let file_size = self.file_size();','        let file_size = self.file_size();')
 code=code.replace('        if offset >= file_size {\n            return Ok(0);\n        }','        if offset >= file_size {\n            crate::tla_trace::event("Ext2ReadAt", crate::tla_trace::take_start(), [file_size, offset, 0, 0, 0, 0, 0, 0]);\n            return Ok(0);\n        }')
 code=code.replace('        writer.limit(read_len);','        writer.limit(read_len);\n        crate::tla_trace::event("Ext2ReadAt", crate::tla_trace::take_start(), [file_size, offset, read_len, writer.avail(), 0, 0, 0, 0]);')
 return code
scope(p,'    fn read_at(&self, offset: usize','    /// Writes file data',inner_read)
def outer_write(code):
 code=code.replace('            return Ok(0);','            crate::tla_trace::event("Ext2WriteAtEmpty", crate::tla_trace::stamp(), [0; 8]);\n            return Ok(0);',1)
 code=code.replace('        let mut inner = self.inner.write();','        let specula_start = crate::tla_trace::stamp();\n        let mut inner = self.inner.write();\n        crate::tla_trace::set_start(specula_start);')
 return code
scope(p,'    pub(in ext2) fn write_at(','    /// Direct-I/O read',outer_write)
wrap(p,'    pub(in ext2) fn write_at(','    /// Direct-I/O read')
def inner_write(code):
 code=code.replace('        let old_size = self.file_size();','        let old_size = self.file_size();\n        crate::tla_trace::event("Ext2WriteAtPrepare", crate::tla_trace::take_start(), [old_size, end, 0, 0, 0, 0, 0, 0]);')
 code=code.replace('        if let Err(err) = self.page_cache().write(offset, reader) {','        crate::tla_trace::event("WriteAtCopyStart", crate::tla_trace::stamp(), [offset, reader.remain(), 0, 0, 0, 0, 0, 0]);\n        if let Err(err) = self.page_cache().write(offset, reader) {')
 code=code.replace('        self.set_mtime_ctime(utils::now());','        let specula_start = crate::tla_trace::stamp();\n        self.set_mtime_ctime(utils::now());')
 code=code.replace('        Ok(write_len)','        crate::tla_trace::event("Ext2WriteAtPublish", specula_start, [self.file_size(), 0, 0, 0, 0, 0, 0, 0]);\n        Ok(write_len)')
 return code
scope(p,'    fn write_at(&mut self, fs: &Ext2','    /// Reads file data directly',inner_write)
def extresize(code):
 code=code.replace('        let mut inner = self.inner.write();','        let specula_start = crate::tla_trace::stamp();\n        let mut inner = self.inner.write();')
 code=code.replace('        let old_size = inner.file_size();','        let old_size = inner.file_size();\n        crate::tla_trace::event("Ext2Resize", specula_start, [old_size, new_size, 0, 0, 0, 0, 0, 0]);')
 code=code.replace('        inner.set_mtime_ctime(utils::now());','        crate::tla_trace::event("Ext2ResizePublish", crate::tla_trace::last_end(), [inner.file_size(), crate::tla_trace::blocks(), 0, 0, 0, 0, 0, 0]);\n        inner.set_mtime_ctime(utils::now());')
 return code
scope(p,'    pub(in ext2) fn resize(','    /// Implements fallocate',extresize)
wrap(p,'    pub(in ext2) fn resize(','    /// Implements fallocate',True)
edit(p,'''    pub(super) fn rollback_write(&mut self, old_size: usize, end: usize) {''','''    pub(super) fn rollback_write(&mut self, old_size: usize, end: usize) {
        crate::tla_trace::event("Ext2RollbackWrite", crate::tla_trace::stamp(), [old_size, end, 0, 0, 0, 0, 0, 0]);''')
def rollback(code):
 code=code.replace('            block_manager.truncate_to_byte_len(old_size);','            block_manager.truncate_to_byte_len(old_size);\n            crate::tla_trace::event("Ext2RollbackBlocks", crate::tla_trace::last_end(), [crate::tla_trace::blocks(), 0, 0, 0, 0, 0, 0, 0]);')
 return code
scope(p,'    pub(super) fn rollback_write(','    /// Truncates only block',rollback)
p=R+'fs/fs_impls/ext2/inode/mod.rs'
edit(p,'        block_manager.set_npages(new_size_bytes.div_ceil(PAGE_SIZE));','''        let specula_start = crate::tla_trace::stamp();
        block_manager.set_npages(new_size_bytes.div_ceil(PAGE_SIZE));
        crate::tla_trace::event("Ext2ResizePageCacheBound", specula_start, [new_size_bytes.div_ceil(PAGE_SIZE), 0, 0, 0, 0, 0, 0, 0]);''')
p=R+'fs/fs_impls/ext2/inode/block_manager/mod.rs'
edit(p,'        tree.truncate_to_byte_len(&fs, new_size)','''        tree.truncate_to_byte_len(&fs, new_size);
        if crate::tla_trace::active() {
            let mut mask = 0;
            for i in 0..12 { if tree.lookup_block(Iblock::try_from(i).unwrap()).unwrap().is_some() { mask |= 1 << i; } }
            crate::tla_trace::set_blocks(mask);
        }''')
# The existing tree W guard protects direct-block receipts; these small fixtures never use indirect blocks.
def allocate(code):
 code=code.replace('        let mut tree = self.block_ptr_tree.write();','        let specula_start = crate::tla_trace::stamp();\n        let mut tree = self.block_ptr_tree.write();\n        let mut fresh = 0usize;\n        crate::tla_trace::reset_zeros();')
 code=code.replace('                ResolvedBlockRange::NewlyAllocated(range) => {','                ResolvedBlockRange::NewlyAllocated(range) => {\n                    for i in current_block..current_block + range.len() { if i < 12 { fresh |= 1 << i; } }')
 code=code.replace('        Ok(())','''        if crate::tla_trace::active() {
            let mut mask = 0;
            for i in 0..12 { if tree.lookup_block(Iblock::try_from(i).unwrap()).unwrap().is_some() { mask |= 1 << i; } }
            crate::tla_trace::set_blocks(mask);
            crate::tla_trace::event("Ext2AllocateRangeBlocks", specula_start, [mask, fresh, crate::tla_trace::zeros(), 0, 0, 0, 0, 0]);
        }
        Ok(())''')
 return code
scope(p,'    pub(super) fn allocate_range_blocks(','    pub(super) fn set_npages(',allocate)

p=R+'fs/fs_impls/exfat/inode.rs'
for name in ('ExfatReadAt','ExfatWriteAtPrepare','ExfatResize'):
    marker='crate::tla_trace::event("'+name+'",'
    edit(p,marker,'crate::tla_trace::bind_vmo(inner.page_cache.as_vmo().as_ref() as *const _ as usize);\n        '+marker)
p=R+'fs/fs_impls/ext2/inode/file.rs'
for name in ('Ext2ReadAt','Ext2WriteAtPrepare'):
    marker='crate::tla_trace::event("'+name+'",'
    count=original(p).count(marker)
    edit(p,marker,'crate::tla_trace::bind_vmo(self.page_cache().as_vmo().as_ref() as *const _ as usize);\n        '+marker,count=count)
marker='crate::tla_trace::event("Ext2Resize",'
edit(p,marker,'crate::tla_trace::bind_vmo(inner.page_cache().as_vmo().as_ref() as *const _ as usize);\n        '+marker)

p=R+'fs/fs_impls/ext2/inode/block_manager/block_ptr_tree.rs'
def zero_receipt(code):
    code=code.replace('        segment_writer.fill_zeros(', '        let specula_before = segment_writer.cursor() as usize;\n        segment_writer.fill_zeros(')
    code=code.replace('        fs.write_blocks_async(', '        let specula_zeroed = segment_writer.cursor() as usize - specula_before;\n        fs.write_blocks_async(')
    code=code.replace('        io_batch.wait_all()?;', '        io_batch.wait_all()?;\n        crate::tla_trace::zero_receipt(specula_zeroed);')
    return code
scope(p,'    fn zero_new_blocks(', '    /// Splices allocated blocks',zero_receipt)
p=R+'fs/fs_impls/ext2/inode/block_manager/mod.rs'
scope(p,'    fn submit_read_bio(','    fn submit_write_bio(',lambda code: code.replace('        if idx >= self.npages.load(Ordering::Acquire) {','        let specula_start = crate::tla_trace::stamp();\n        if idx >= self.npages.load(Ordering::Acquire) {\n            crate::tla_trace::event("VmoRangeError", specula_start, [1, 0, 0, 0, 0, 0, 0, 0]);'))
p=R+'fs/fs_impls/exfat/inode.rs'
scope(p,'    fn submit_read_bio(','    fn submit_write_bio(',lambda code: code.replace('        if inner.size_allocated <= idx * PAGE_SIZE {','        if inner.size_allocated <= idx * PAGE_SIZE {\n            crate::tla_trace::event("VmoRangeError", crate::tla_trace::stamp(), [1, 0, 0, 0, 0, 0, 0, 0]);'))
def nested_probe(code):
    return code.replace('        let inner = self.inner.read();', '\n'.join([
        '        if crate::tla_trace::holds_writer() {',
        '            let specula_start = crate::tla_trace::stamp();',
        '            if self.inner.try_read().is_none() {',
        '                crate::tla_trace::event("ExfatBackendReadBlocked", specula_start, [0; 8]);',
        '            }',
        '        }',
        '        let inner = self.inner.read();']), 1)
scope(p,'    fn submit_read_bio(', '    fn submit_write_bio(',nested_probe)
