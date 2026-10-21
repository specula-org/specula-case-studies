#!/usr/bin/env python3
"""Build the instrumentation patch from the pinned source, without resetting it."""
import difflib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3] / 'source'
OUT = Path(__file__).resolve().parents[1] / 'patches'
PIN = '0c60537098f4c2949ad2d382aaf499de72263d76'
originals = {}
changed = {}

def edit(path, old, new, count=1):
    if path not in originals:
        originals[path] = subprocess.check_output(['git', 'show', f'{PIN}:{path}'], cwd=ROOT).decode()
        changed[path] = originals[path]
    assert changed[path].count(old) == count, (path, old[:90], changed[path].count(old))
    changed[path] = changed[path].replace(old, new)

K = 'kernel/core/src/'
edit('ostd/src/arch/x86/mod.rs', '/// Reads a hardware generated 64-bit random value.',
     'pub use timer::hpet::{init_trace_clock, read_trace_clock, trace_clock_period};\n\n/// Reads a hardware generated 64-bit random value.')
edit('ostd/src/arch/x86/timer/mod.rs', 'mod hpet;', 'pub(super) mod hpet;')
edit('ostd/src/arch/x86/timer/hpet.rs', '    mm::paddr_to_vaddr,', '    io::IoMem,\n    mm::{paddr_to_vaddr, VmIoOnce},')
edit('ostd/src/arch/x86/timer/hpet.rs', 'static HPET_INSTANCE: Once<Hpet> = Once::new();',
     'static HPET_INSTANCE: Once<Hpet> = Once::new();' + '\nstruct TraceClock {\n    registers: IoMem,\n    period: u32,\n}\n\nstatic TRACE_CLOCK: Once<TraceClock> = Once::new();\n\n/// Enables the shared HPET counter before the private tracing fixture starts.\npub fn init_trace_clock() {\n    TRACE_CLOCK.call_once(|| {\n        let info = HpetInfo::new(get_acpi_tables().unwrap()).unwrap();\n        let base = info.base_address;\n        // MMIO is outside the RAM direct map and needs its own uncached mapping.\n        let registers = IoMem::acquire(base..base + 4096).unwrap();\n        let capabilities = registers.read_once::<u32>(0).unwrap();\n        assert_ne!(capabilities & 0x2000, 0);\n        let period = registers.read_once::<u32>(4).unwrap();\n        let configuration = registers.read_once::<u32>(0x10).unwrap();\n        // The fixture must not enable firmware timer interrupts or legacy routing.\n        assert_eq!(configuration & 2, 0);\n        for timer in 0..=((capabilities >> 8) & 31) {\n            assert_eq!(\n                registers\n                    .read_once::<u32>(0x100 + timer as usize * 0x20)\n                    .unwrap()\n                    & 4,\n                0\n            );\n        }\n        registers.write_once(0x10, &(configuration | 1)).unwrap();\n        TraceClock { registers, period }\n    });\n}\n\n/// Returns the hardware counter period in femtoseconds.\npub fn trace_clock_period() -> u32 {\n    TRACE_CLOCK.get().unwrap().period\n}\n\n/// Reads the shared counter without a tracing lock or software sequence number.\npub fn read_trace_clock() -> u64 {\n    let Some(clock) = TRACE_CLOCK.get() else {\n        return 0;\n    };\n    // SAFETY: MFENCE orders memory effects around the single, uncached MMIO read.\n    unsafe { core::arch::x86_64::_mm_mfence() };\n    let value = clock.registers.read_once::<u64>(0xf0).unwrap();\n    // SAFETY: The fence has no memory-safety preconditions.\n    unsafe { core::arch::x86_64::_mm_mfence() };\n    value\n}\n')
edit(K+'lib.rs', 'mod sched;', 'mod sched;\npub(crate) mod scm_trace;')
edit(K+'process/posix_thread/thread_local.rs', 'pub(crate) struct ThreadLocal {',
     'pub(crate) struct ThreadLocal {\n    pub(crate) scm_trace: RefCell<Option<crate::scm_trace::Buffer>>,')
edit(K+'process/posix_thread/thread_local.rs', 'set_child_tid: Cell::new(set_child_tid),',
     'scm_trace: RefCell::new(None),\n            set_child_tid: Cell::new(set_child_tid),')
edit(K+'syscall/prctl.rs', '    let prctl_cmd = PrctlCmd::from_args', '''    if (0x53504300..=0x53504305).contains(&option) {
        return crate::scm_trace::control(option, arg2, arg3, arg4, arg5, ctx)
            .map(|value| SyscallReturn::Return(value as _));
    }
    let prctl_cmd = PrctlCmd::from_args''')
for name, receive in [('sendmsg', 'false'), ('recvmsg', 'true')]:
    edit(K+f'syscall/{name}.rs', '    let user_space = ctx.user_space();', f'''    let _trace_complete = crate::scm_trace::Complete({receive});
    crate::scm_trace::begin({receive});
    let user_space = ctx.user_space();''')
edit(K+'syscall/recvmsg.rs', '    drop(file_table);', '''    let trace_start = crate::scm_trace::stamp();
    drop(file_table);
    let trace_end = crate::scm_trace::stamp();
    crate::scm_trace::emit("SysRecvmsgReleaseBorrow", trace_start, trace_end, &[]);''')
edit(K+'syscall/recvmsg.rs', '    user_space.write_val(user_msghdr_ptr, &c_user_msghdr)?;', '''    let trace_start = crate::scm_trace::stamp();
    user_space.write_val(user_msghdr_ptr, &c_user_msghdr)?;
    let trace_end = crate::scm_trace::stamp();
    crate::scm_trace::emit("SysRecvmsgWriteback", trace_start, trace_end,
        &[control_len as usize, control_flags.bits() as usize, output.len()]);''')

# The observed writer preserves the original rewind and reports the copied prefix.
p = 'ostd/src/mm/io/mod.rs'
edit(p, '''    pub fn write_val<T: Pod>(&mut self, new_val: &T) -> Result<()> {
        if self.avail() < size_of::<T>() {
            return Err(Error::InvalidArgs);
        }

        let mut reader = VmReader::from(new_val.as_bytes());
        self.write_fallible(&mut reader)
            .map_err(|(err, copied_len)| {''', '''    pub fn write_val<T: Pod>(&mut self, new_val: &T) -> Result<()> {
        self.write_val_observed(new_val).map_err(|(err, _)| err)
    }

    /// Reports the copied prefix before restoring the cursor on a failed value copy.
    pub fn write_val_observed<T: Pod>(&mut self, new_val: &T) -> core::result::Result<(), (Error, usize)> {
        if self.avail() < size_of::<T>() {
            return Err((Error::InvalidArgs, 0));
        }

        let mut reader = VmReader::from(new_val.as_bytes());
        self.write_fallible(&mut reader)
            .map_err(|(err, copied_len)| {''')
edit(p, '''        self.write_fallible(&mut reader)
            .map_err(|(err, copied_len)| {
                // The `copied_len` is the number of bytes written so far.
                // So the `cursor` can be moved back to the original position.
                self.cursor = self.cursor.wrapping_sub(copied_len);
                err
            })?;''', '''        self.write_fallible(&mut reader)
            .map_err(|(err, copied_len)| {
                // Preserve both the covered bytes and the original rewind.
                self.cursor = self.cursor.wrapping_sub(copied_len);
                (err, copied_len)
            })?;''')

p = K+'net/socket/unix/ctrl_msg.rs'
edit(p, 'use core::{fmt, mem};', 'use core::{fmt, mem};\nuse crate::scm_trace as tr;')
edit(p, '''            let file = get_file_fast!(&mut file_table, fd.try_into()?).into_owned();
            files.push(file);''', '''            let start = tr::stamp();
            let file = get_file_fast!(&mut file_table, fd.try_into()?).into_owned();
            files.push(file);
            let end = tr::stamp();
            tr::emit("FileMessageReadFrom", start, end,
                &[fd as usize, tr::ptr(files.last().unwrap()), files.len()]);''')
edit(p, '''        let nfiles = self
            .files
            .len()
            .min(CControlHeader::payload_len_from_total(writer.avail())? / size_of::<i32>());''', '''        let start = tr::stamp();
        let capacity = CControlHeader::payload_len_from_total(writer.avail());
        if capacity.is_err() {
            tr::emit("FileMessageWriteCapacity", start, tr::stamp(), &[0, writer.avail()]);
        }
        let nfiles = self.files.len().min(capacity? / size_of::<i32>());
        let end = tr::stamp();
        tr::emit("FileMessageWriteCapacity", start, end, &[nfiles, writer.avail()]);''')
edit(p, '        writer.write_val::<CControlHeader>(&header)?;', '''        let start = tr::stamp();
        let result = writer.write_val_observed::<CControlHeader>(&header);
        let end = tr::stamp();
        tr::emit("FileMessageWriteHeader", start, end,
            &[result.is_ok() as usize, result.as_ref().err().map_or(size_of::<CControlHeader>(), |(_, n)| *n),
              writer.cursor() as usize, header.total_len()]);
        result.map_err(|(err, _)| err)?;''')
edit(p, '        for file in self.files[..nfiles].iter() {',
     '        for (index, file) in self.files[..nfiles].iter().enumerate() {')
edit(p, '''            let fd = file_table
                .unwrap()
                .write()
                .insert(file.clone(), FdFlags::empty());''', '''            let fd = {
                let mut table = file_table.unwrap().write();
                let start = tr::stamp();
                let fd = table.insert(file.clone(), FdFlags::empty());
                let end = tr::stamp();
                table.get_entry_mut(fd).unwrap().scm_origin = tr::origin(index + 1);
                tr::emit("FileTableInsert", start, end,
                    &[usize::from(fd), tr::ptr(table.get_file(fd).unwrap()), index + 1]);
                fd
            };''')
edit(p, '            writer.write_val::<i32>(&(fd.into()))?;', '''            let start = tr::stamp();
            let result = writer.write_val_observed::<i32>(&(fd.into()));
            let end = tr::stamp();
            tr::emit("VmWriterWriteFd", start, end,
                &[result.is_ok() as usize, result.as_ref().err().map_or(4, |(_, n)| *n),
                  writer.cursor() as usize, index + 1, usize::from(fd)]);
            result.map_err(|(err, _)| err)?;''')
edit(p, '''                Message::Files(FileMessage {
                    files: mut msg_files,
                }) => {''', '''                Message::Files(mut msg) => {
                    let msg_files = &mut msg.files;''')
edit(p, '                    files.append(&mut msg_files);', '''                    let start = tr::stamp();
                    files.append(msg_files);
                    let end = tr::stamp();
                    let ids = trace_ids(&files);
                    tr::emit("AuxiliaryDataFromControl", start, end, &ids);''')
edit(p, '''            let files = match behavior {
                ReceiveBehavior::Recv => mem::take(files),
                ReceiveBehavior::Peek => files.clone(),
            };
            let unix_ctrl_msg = UnixControlMessage(Message::Files(FileMessage { files }));
            ctrl_msgs.push(ControlMessage::Unix(unix_ctrl_msg));''', '''            let before = trace_ids(files);
            let start = tr::stamp();
            let generated = match behavior {
                ReceiveBehavior::Recv => mem::take(files),
                ReceiveBehavior::Peek => files.clone(),
            };
            let end = tr::stamp();
            let after = trace_ids(files);
            let copied = trace_ids(&generated);
            let mut data = [0; 12];
            data[..4].copy_from_slice(&before);
            data[4..8].copy_from_slice(&after);
            data[8..].copy_from_slice(&copied);
            tr::emit(match behavior {
                ReceiveBehavior::Recv => "AuxiliaryDataGenerateControlRecv",
                ReceiveBehavior::Peek => "AuxiliaryDataGenerateControlPeek",
            }, start, end, &data);
            let unix_ctrl_msg = UnixControlMessage(Message::Files(FileMessage { files: generated }));
            ctrl_msgs.push(ControlMessage::Unix(unix_ctrl_msg));''')
edit(p, 'impl AuxiliaryData {', '''fn trace_ids(files: &[Arc<dyn FileLike>]) -> [usize; 4] {
    let mut ids = [0; 4];
    for (dest, file) in ids.iter_mut().zip(files) { *dest = tr::ptr(file); }
    ids
}

impl Drop for FileMessage {
    fn drop(&mut self) {
        if tr::enabled() {
            for file in self.files.drain(..) { tr::release(file, false); }
        }
    }
}

impl Drop for AuxiliaryData {
    fn drop(&mut self) {
        if tr::enabled() {
            for file in self.files.drain(..) { tr::release(file, tr::mode() == 0); }
        }
    }
}

impl AuxiliaryData {
    pub(super) fn trace_ids(&self) -> [usize; 4] { trace_ids(&self.files) }''')

p = K+'net/socket/unix/datagram/message.rs'
edit(p, 'use spin::Once;', 'use spin::Once;\nuse crate::scm_trace as tr;')
edit(p, 'struct Inner {', '''struct Inner {
    trace_enqueued: usize,
    trace_consumed: usize,
    trace_disposed: usize,''')
edit(p, 'struct Message {', 'struct Message {\n    trace_generation: usize,')
edit(p, '        let inner = Inner {', '''        let inner = Inner {
            trace_enqueued: 0,
            trace_consumed: 0,
            trace_disposed: 0,''')
edit(p, 'impl MessageQueue {', '''impl Inner {
    fn trace(&self, queue: usize) -> [usize; 16] {
        let mut v = [0; 16];
        v[0] = queue;
        v[1] = self.messages.len();
        if let Some(message) = self.messages.front() {
            v[2] = message.trace_generation;
            v[3..7].copy_from_slice(&message.aux.trace_ids());
            v[10] = message.bytes.len();
        }
        v[7] = self.trace_enqueued;
        v[8] = self.trace_consumed;
        v[9] = self.trace_disposed;
        v
    }
}

impl MessageQueue {''')
edit(p, '''        let mut inner = self.inner.lock();
        let Some(inner) = inner.as_mut() else {''', '''        let qid = self as *const Self as usize;
        tr::queue(qid, true);
        let mut guard = self.inner.lock();
        let locked = tr::stamp();
        let Some(inner) = guard.as_mut() else {''')
edit(p, '''        if inner.is_shutdown {
            return_errno_with_message!(Errno::EPIPE''', '''        tr::emit("MessageQueueTrySendLock", locked, locked, &inner.trace(qid));
        if inner.is_shutdown {
            return_errno_with_message!(Errno::EPIPE''')
edit(p, '            reader.read(&mut VmWriter::from(bytes.as_mut_slice()))?;', '''            let start = tr::stamp();
            let result = reader.read(&mut VmWriter::from(bytes.as_mut_slice()));
            let end = tr::stamp();
            tr::emit("MessageQueueTrySendCopy", start, end, &[result.is_ok() as usize, result.as_ref().copied().unwrap_or_else(|(_, n)| *n)]);
            if let Err(err) = result {
                let snapshot = inner.trace(qid);
                let start = tr::stamp();
                drop(guard);
                let end = tr::stamp();
                tr::emit("MessageQueueTrySendUnlock", start, end, &snapshot);
                return Err(err.into());
            }''')
edit(p, '        let msg = {', '        let enqueue_start;\n        let msg = {')
edit(p, '            let mut aux = core::mem::take(aux_data);',
     '            enqueue_start = tr::stamp();\n            let mut aux = core::mem::take(aux_data);')
edit(p, '            Message { bytes, aux, src }',
     '            Message { bytes, aux, src, trace_generation: inner.trace_enqueued + 1 }')
edit(p, '        inner.messages.push_back(msg);', '''        inner.messages.push_back(msg);
        let enqueue_end = tr::stamp();
        inner.trace_enqueued += 1;
        tr::emit("MessageQueueTrySendEnqueue", enqueue_start, enqueue_end, &inner.trace(qid));''')
edit(p, '''        self.pollee.notify(IoEvents::IN);

        Ok(len)''', '''        self.pollee.notify(IoEvents::IN);
        let snapshot = inner.trace(qid);
        let start = tr::stamp();
        drop(guard);
        let end = tr::stamp();
        tr::emit("MessageQueueTrySendUnlock", start, end, &snapshot);
        Ok(len)''')
edit(p, '''        let mut inner = self.queue.inner.lock();
        let inner = inner.as_mut().unwrap();

        let Some(msg) = inner.messages.front() else {''', '''        let qid = Arc::as_ptr(&self.queue) as usize;
        tr::queue(qid, true);
        let mut guard = self.queue.inner.lock();
        let locked = tr::stamp();
        let inner = guard.as_mut().unwrap();
        tr::emit("MessageReceiverTryRecvLock", locked, locked, &inner.trace(qid));
        let select_start = tr::stamp();
        let selected = inner.messages.front();
        let select_end = tr::stamp();
        tr::emit("MessageReceiverTryRecvSelect", select_start, select_end, &inner.trace(qid));
        let Some(msg) = selected else {''')
edit(p, '''            if !inner.is_shutdown {
                return_errno_with_message!(Errno::EAGAIN, "the receive buffer is empty");''', '''            if !inner.is_shutdown {
                let snapshot = inner.trace(qid);
                let start = tr::stamp();
                drop(guard);
                let end = tr::stamp();
                tr::emit("MessageReceiverTryRecvUnlock", start, end, &snapshot);
                return_errno_with_message!(Errno::EAGAIN, "the receive buffer is empty");''')
edit(p, '        let len = writer.write(&mut VmReader::from(msg.bytes.as_slice()))?;', '''        let start = tr::stamp();
        let result = writer.write(&mut VmReader::from(msg.bytes.as_slice()));
        let end = tr::stamp();
        let mut snapshot = inner.trace(qid);
        snapshot[11] = result.is_ok() as usize;
        snapshot[12] = result.as_ref().copied().unwrap_or_else(|(_, n)| *n);
        tr::emit("MessageReceiverTryRecvCopy", start, end, &snapshot);
        let len = match result {
            Ok(len) => len,
            Err(err) => {
                let snapshot = inner.trace(qid);
                let start = tr::stamp();
                drop(guard);
                let end = tr::stamp();
                tr::emit("MessageReceiverTryRecvUnlock", start, end, &snapshot);
                return Err(err.into());
            }
        };''')
edit(p, '''            let mut message = inner.messages.pop_front().unwrap();
            inner.total_length -= message.bytes.len();''', '''            let start = tr::stamp();
            let mut message = inner.messages.pop_front().unwrap();
            inner.total_length -= message.bytes.len();
            let end = tr::stamp();
            inner.trace_consumed += 1;
            let mut snapshot = inner.trace(qid);
            snapshot[11..15].copy_from_slice(&message.aux.trace_ids());
            snapshot[15] = message.trace_generation;
            tr::emit("MessageReceiverTryRecvDequeue", start, end, &snapshot);''')
edit(p, '''        let output = RecvOutput::new_for_packet(flags, len, message_len);
        Ok((output, ctrl_msgs, src))''', '''        let output = RecvOutput::new_for_packet(flags, len, message_len);
        let snapshot = inner.trace(qid);
        let start = tr::stamp();
        drop(guard);
        let end = tr::stamp();
        tr::emit("MessageReceiverTryRecvUnlock", start, end, &snapshot);
        Ok((output, ctrl_msgs, src))''')
edit(p, '        *self.queue.inner.lock() = None;', '''        let qid = Arc::as_ptr(&self.queue) as usize;
        if tr::queue(qid, false) {
            let mut guard = self.queue.inner.lock();
            let start = tr::stamp();
            let old = guard.take();
            let end = tr::stamp();
            let snapshot = old.as_ref().unwrap().trace(qid);
            tr::emit("MessageReceiverDropBegin", start, end, &snapshot);
            drop(old);
            let start = tr::stamp();
            drop(guard);
            let end = tr::stamp();
            tr::emit("MessageReceiverDropComplete", start, end, &[qid]);
        } else {
            *self.queue.inner.lock() = None;
        }''')

p = K+'net/socket/util/message_header.rs'
edit(p, '''        let mut len = 0;
        let mut output_flags = RecvFlags::empty();''', '''        let mut len = 0;
        let mut output_flags = RecvFlags::empty();''')
# Nested per-entry steps finish before this reporting boundary starts.
edit(p, '''        (len, output_flags)
    }''', '''        let t = crate::scm_trace::stamp();
        crate::scm_trace::emit("ControlMessageWriteAllTo", t, t,
            &[len, output_flags.bits() as usize, writer.cursor() as usize]);
        (len, output_flags)
    }''')
p = K+'util/net/socket.rs'
edit(p, '            return Ok((0, output_flags));', '''            let t = crate::scm_trace::stamp();
            crate::scm_trace::emit("CUserMsgHdrWriteControl", t, t,
                &[1, self.msg_controllen, output_flags.bits() as usize]);
            return Ok((0, output_flags));''')
edit(p, '        let mut writer = user_space.writer(self.msg_control, self.msg_controllen)?;', '''        let start = crate::scm_trace::stamp();
        let mut writer = user_space.writer(self.msg_control, self.msg_controllen)?;
        let end = crate::scm_trace::stamp();
        crate::scm_trace::emit("CUserMsgHdrWriteControl", start, end,
            &[0, self.msg_controllen, self.msg_control]);''')

p = K+'fs/file/file_table.rs'
edit(p, 'pub(crate) struct FileTableEntry {',
     'pub(crate) struct FileTableEntry {\n    pub(crate) scm_origin: [usize; 3],')
edit(p, '            flags: AtomicU8::new(flags.bits()),',
     '            flags: AtomicU8::new(flags.bits()),\n            scm_origin: [0; 3],')
edit(p, '            flags: AtomicU8::new(self.flags.load(Ordering::Relaxed)),',
     '            flags: AtomicU8::new(self.flags.load(Ordering::Relaxed)),\n            scm_origin: self.scm_origin,')
p = K+'syscall/close.rs'
edit(p, '''    let closed_file = {
        let fd = raw_fd.try_into()?;''', '''    let mut trace_object = 0;
    let closed_file = {
        let fd = raw_fd.try_into()?;''')
edit(p, '''        let _ = file_table_locked.get_file(fd)?;
        file_table_locked.close_file(fd).unwrap()''', '''        let file = file_table_locked.get_file(fd)?;
        if crate::scm_trace::ordinary(file) { trace_object = crate::scm_trace::ptr(file); }
        let origin = file_table_locked.get_entry(fd)?.scm_origin;
        let start = crate::scm_trace::stamp();
        let closed = file_table_locked.close_file(fd).unwrap();
        let end = crate::scm_trace::stamp();
        if trace_object != 0 {
            crate::scm_trace::emit("FileTableCloseFile", start, end,
                &[raw_fd as usize, trace_object, origin[0], origin[1], origin[2]]);
        }
        closed''')
edit(p, '    drop(closed_file);', '''    let start = crate::scm_trace::stamp();
    drop(closed_file);
    let end = crate::scm_trace::stamp();
    if trace_object != 0 {
        crate::scm_trace::emit("ClosedFileDrop", start, end, &[raw_fd as usize, trace_object]);
    }''')
p = K+'syscall/dup.rs'
edit(p, '''        file_table_locked.dup_exact(old_fd, new_fd, flags)?''', '''        let start = crate::scm_trace::stamp();
        let replaced = file_table_locked.dup_exact(old_fd, new_fd, flags)?;
        let end = crate::scm_trace::stamp();
        let file = file_table_locked.get_file(new_fd)?;
        if crate::scm_trace::ordinary(file) {
            crate::scm_trace::emit("SenderReuse", start, end,
                &[usize::from(new_fd), crate::scm_trace::ptr(file)]);
        }
        replaced''')
OUT.mkdir(exist_ok=True)
path = 'OSDK.toml'
originals[path] = subprocess.check_output(['git', 'show', f'{PIN}:{path}'], cwd=ROOT).decode()
changed[path] = originals[path] + '''
[scheme."scm-trace"]
boot.method = "grub-rescue-iso"
qemu.args = "-bios /root/ovmf/release/OVMF.fd -machine q35,kernel-irqchip=split -m 2G -smp 2 -cpu host -accel kvm -nographic -monitor none -no-reboot -device isa-debug-exit,iobase=0xf4,iosize=0x04"
'''
patch = ''.join(''.join(difflib.unified_diff(originals[p].splitlines(True), text.splitlines(True),
                       fromfile='a/'+p, tofile='b/'+p)) for p, text in changed.items() if text != originals[p])
(OUT/'instrumentation.patch').write_text(patch)
print(f'Wrote {len(changed)} file patch ({len(patch)} bytes)')
