p=R+'vm/page_cache/mod.rs'
edit(p,'''        let vmo = &self.0;
        assert!(vmo.flags.contains(VmoFlags::RESIZABLE));''','''        let specula_start = crate::tla_trace::stamp();
        let vmo = &self.0;
        assert!(vmo.flags.contains(VmoFlags::RESIZABLE));''')
edit(p,'            self.fill_zeros(new_file_size..fill_zero_end)?;', '''            crate::tla_trace::event("PageCacheResizeBegin", specula_start, [new_file_size, old_file_size, new_file_size, fill_zero_end, 0, 0, 0, 0]);
            self.fill_zeros(new_file_size..fill_zero_end)?;''')
edit(p,'''            self.fill_zeros(old_file_size..fill_zero_end)?;
        }

        let rmap''','''            crate::tla_trace::event("PageCacheResizeBegin", specula_start, [new_file_size, old_file_size, old_file_size, fill_zero_end, 0, 0, 0, 0]);
            self.fill_zeros(old_file_size..fill_zero_end)?;
        } else {
            let lo = new_file_size.min(old_file_size);
            crate::tla_trace::event("PageCacheResizeBegin", specula_start, [new_file_size, old_file_size, lo, lo, 0, 0, 0, 0]);
        }

        let rmap''')
edit(p,'''        if new_cache_size == old_cache_size {
            return Ok(());
        }

        vmo.size.store''','''        if new_cache_size == old_cache_size {
            let specula_start = crate::tla_trace::stamp();
            crate::tla_trace::event("PageCacheResizeCapacity", specula_start, [old_cache_size, new_cache_size, 0, 0, 0, 0, 0, 0]);
            return Ok(());
        }

        vmo.size.store''')
# Capacity publication precedes potentially blocking decommit; its interval must include both.
edit(p,'        let new_cache_size = new_file_size.align_up(PAGE_SIZE);','''        let specula_start = crate::tla_trace::stamp();
        let new_cache_size = new_file_size.align_up(PAGE_SIZE);''')
edit(p,'''                vmo.decommit_anon_pages(locked_rmap, locked_pages, decommit_range)?;
            }
        }

        Ok(())''','''                vmo.decommit_anon_pages(locked_rmap, locked_pages, decommit_range)?;
            }
        }
        crate::tla_trace::event("PageCacheResizeCapacity", specula_start, [old_cache_size, new_cache_size, usize::from(new_file_size < old_file_size), 0, 0, 0, 0, 0]);

        Ok(())''')
p=R+'vm/page_cache/vmo/mod.rs'
edit(p,'''        let read_len = writer.avail().min(self.size().saturating_sub(offset));''','''        let specula_start = crate::tla_trace::stamp();
        let read_len = writer.avail().min(self.size().saturating_sub(offset));
        crate::tla_trace::event("VmoIoBegin", specula_start, [offset, writer.avail(), read_len, 0, 0, 0, 0, 0]);''')
edit(p,'''        let write_len = reader.remain().min(self.size().saturating_sub(offset));''','''        let specula_start = crate::tla_trace::stamp();
        let write_len = reader.remain().min(self.size().saturating_sub(offset));
        crate::tla_trace::event("VmoIoBegin", specula_start, [offset, reader.remain(), write_len, 0, 0, 0, 0, 0]);''')
edit(p,'''            for (_, page) in page_batch.iter() {
                page.reader().skip(page_offset).read_fallible(writer)?;
                page_offset = 0;
            }''','''            for (idx, page) in page_batch.iter() {
                let specula_start = crate::tla_trace::stamp();
                let before = writer.cursor() as usize;
                let result = page.reader().skip(page_offset).read_fallible(writer);
                crate::tla_trace::copied(specula_start, *idx, page_offset, before, writer.cursor() as usize,
                    result.is_err(), page.state() as usize, page.reader(), true);
                result?;
                page_offset = 0;
            }''')
edit(p,'''            for (_, page) in page_batch.iter() {
                page.writer().skip(*page_offset).write_fallible(reader)?;
                *page_offset = 0;
            }''','''            for (idx, page) in page_batch.iter() {
                let specula_start = crate::tla_trace::stamp();
                let before = reader.cursor() as usize;
                let result = page.writer().skip(*page_offset).write_fallible(reader);
                crate::tla_trace::copied(specula_start, *idx, *page_offset, before, reader.cursor() as usize,
                    result.is_err(), page.state() as usize, page.reader(), false);
                result?;
                *page_offset = 0;
            }''')
edit(p,'''                let written_size = match locked_page
''','''                let specula_start = crate::tla_trace::stamp();
                let before = reader.cursor() as usize;
                let written_size = match locked_page
''')
edit(p,'''                        return Err(Error::from(err));
                    }
                };

                if written_size > 0''','''                        crate::tla_trace::copied(specula_start, idx, *page_offset, before, reader.cursor() as usize,
                            true, locked_page.state() as usize, locked_page.reader(), false);
                        return Err(Error::from(err));
                    }
                };

                if written_size > 0''')
edit(p,'''                    locked_page.set_dirty();
                }

                *page_offset = 0;''','''                    locked_page.set_dirty();
                }
                crate::tla_trace::copied(specula_start, idx, *page_offset, before, reader.cursor() as usize,
                    false, locked_page.state() as usize, locked_page.reader(), false);

                *page_offset = 0;''')
edit(p,'''        if range.end > self.size() {
            return_errno_with_message!(Errno::EINVAL, "the range to fill exceeds the VMO size");
        }

        static ZERO_PAGE''','''        let specula_start = crate::tla_trace::stamp();
        if range.end > self.size() {
            crate::tla_trace::event("VmoRangeError", specula_start, [0; 8]);
            return_errno_with_message!(Errno::EINVAL, "the range to fill exceeds the VMO size");
        }
        crate::tla_trace::event("PageCacheFillZeros", specula_start, [range.start, range.end, 0, 0, 0, 0, 0, 0]);

        static ZERO_PAGE''')
edit(p,'''        let end_idx = end_idx.min(start_idx + pages.capacity());
        pages.clear();''','''        let specula_start = crate::tla_trace::stamp();
        let end_idx = end_idx.min(start_idx + pages.capacity());
        crate::tla_trace::event("VmoCollectBegin", specula_start, [start_idx, end_idx, usize::from(commit_mode.skips_backend_read()), 0, 0, 0, 0, 0]);
        pages.clear();''')
edit(p,'''                    pages.push((idx, page));
                    Ok(())''','''                    let specula_start = crate::tla_trace::stamp();
                    pages.push((idx, page));
                    crate::tla_trace::event("VmoCollectedPage", specula_start, [idx, 0, 0, 0, 0, 0, 0, 0]);
                    Ok(())''')
edit(p,'''                    pages.push((idx, page));
                    current_range.start''','''                    let specula_start = crate::tla_trace::stamp();
                    pages.push((idx, page));
                    crate::tla_trace::event("VmoCollectedPage", specula_start, [idx, 0, 0, 0, 0, 0, 0, 0]);
                    current_range.start''')
# Anonymous allocation and resident fast paths.
edit(p,'''    fn commit_on_anonymous(&self, page_idx: usize) -> Result<CachePage> {
        let mut locked_pages''','''    fn commit_on_anonymous(&self, page_idx: usize) -> Result<CachePage> {
        let specula_start = crate::tla_trace::stamp();
        let mut locked_pages''')
edit(p,'''        if let Some(page) = cursor.load() {
            return Ok(page.clone());
        }

        let new_page''','''        if let Some(page) = cursor.load() {
            crate::tla_trace::page("VmoCommitPage", specula_start, page_idx, page.state() as usize, page.reader());
            return Ok(page.clone());
        }

        let new_page''')
edit(p,'''        cursor.store(new_page.clone());
        Ok(new_page)''','''        cursor.store(new_page.clone());
        crate::tla_trace::page("VmoCommitPage", specula_start, page_idx, new_page.state() as usize, new_page.reader());
        Ok(new_page)''')
edit(p,'''        } else if let Some(page) = cursor.load() {
            let index = cursor.index() as usize;
            return Ok((index, page.clone()));''','''        } else if let Some(page) = cursor.load() {
            let specula_start = crate::tla_trace::stamp();
            let index = cursor.index() as usize;
            crate::tla_trace::page("VmoCommitPage", specula_start, index, page.state() as usize, page.reader());
            return Ok((index, page.clone()));''')
# Backed fallback and initialized recheck retain actual page state and bytes.
edit(p,'''            VmoCommitError::WaitUntilInit { index, page } => {
                page.ensure_init''','''            VmoCommitError::WaitUntilInit { index, page } => {
                let specula_start = crate::tla_trace::stamp();
                page.ensure_init''')
edit(p,'''                })?;
                Ok((index, page))''','''                })?;
                crate::tla_trace::page("VmoBackendRead", specula_start, index, page.state() as usize, page.reader());
                Ok((index, page))''')
edit(p,'''    fn commit_on_internal(&self, page_idx: usize, commit_mode: CommitMode) -> Result<CachePage> {
        let mut locked_pages''','''    fn commit_on_internal(&self, page_idx: usize, commit_mode: CommitMode) -> Result<CachePage> {
        let specula_start = crate::tla_trace::stamp();
        let mut locked_pages''')
edit(p,'''            let page = page.clone();
            drop(locked_pages);

            if !commit_mode''','''            let page = page.clone();
            crate::tla_trace::page("VmoCommitPage", specula_start, page_idx, page.state() as usize, page.reader());
            drop(locked_pages);

            if !commit_mode''')
edit(p,'''                page.ensure_init(|locked_page| self.backend.read_page(page_idx, locked_page))?;
                return Ok(page);''','''                let specula_start = crate::tla_trace::stamp();
                let was_uninit = page.state().is_uninit();
                page.ensure_init(|locked_page| self.backend.read_page(page_idx, locked_page))?;
                if was_uninit { crate::tla_trace::page("VmoBackendRead", specula_start, page_idx, page.state() as usize, page.reader()); }
                return Ok(page);''')
edit(p,'''        cursor.store(uninit_page.clone());
        drop(locked_pages);''','''        cursor.store(uninit_page.clone());
        crate::tla_trace::page("VmoCommitPage", specula_start, page_idx, uninit_page.state() as usize, uninit_page.reader());
        drop(locked_pages);''')
edit(p,'''            uninit_page.ensure_init(|locked_page| self.backend.read_page(page_idx, locked_page))?;
            Ok(uninit_page)''','''            let specula_start = crate::tla_trace::stamp();
            uninit_page.ensure_init(|locked_page| self.backend.read_page(page_idx, locked_page))?;
            crate::tla_trace::page("VmoBackendRead", specula_start, page_idx, uninit_page.state() as usize, uninit_page.reader());
            Ok(uninit_page)''')
edit(p,'''        let page_idx = cursor.index() as usize;

        let Some(page) = cursor.load()''','''        let specula_start = crate::tla_trace::stamp();
        let page_idx = cursor.index() as usize;

        let Some(page) = cursor.load()''')
edit(p,'''        // Check if the page is initialized.
        if !commit_mode.skips_backend_read()''','''        crate::tla_trace::page("VmoCommitPage", specula_start, page_idx, page.state() as usize, page.reader());
        // Check if the page is initialized.
        if !commit_mode.skips_backend_read()''')

p=R+'vm/page_cache/vmo/mod.rs'
for begin in ('pub(crate) fn read(&self, offset: usize, writer: &mut VmWriter) -> Result<()> {',
              'pub(crate) fn write(&self, offset: usize, reader: &mut VmReader) -> Result<()> {',
              'pub(super) fn fill_zeros(&self, range: Range<usize>) -> Result<()> {'):
    edit(p, begin, begin+'\n        let _specula_scope = crate::tla_trace::scope(self as *const Self as usize);')
p=R+'vm/page_cache/mod.rs'
begin='pub(crate) fn resize(&mut self, new_file_size: usize, old_file_size: usize) -> Result<()> {'
edit(p,begin,begin+'\n        let _specula_scope = crate::tla_trace::scope(self.as_vmo().as_ref() as *const _ as usize);')
