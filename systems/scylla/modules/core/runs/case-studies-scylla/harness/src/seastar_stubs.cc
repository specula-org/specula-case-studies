/*
 * Minimal stubs for symbols NOT provided by the Seastar source files
 * we compile (future.cc, log.cc, condition-variable.cc, semaphore.cc).
 *
 * Only provides: on_internal_error, error_injection, sstring helpers, and
 * other miscellaneous symbols that live in Seastar sources we don't compile.
 */

// Only include headers needed for stubs; avoid headers whose symbols
// are provided by the Seastar .cc files we compile separately.
#include <seastar/core/on_internal_error.hh>

#include <cstdio>
#include <cstdlib>
#include <stdexcept>

// ---------------------------------------------------------------------------
// seastar::on_internal_error (lives in seastar/src/core/on_internal_error.cc)
// ---------------------------------------------------------------------------

[[noreturn]] void seastar::on_internal_error(seastar::logger&, std::string_view reason) {
    fprintf(stderr, "FATAL: %.*s\n", static_cast<int>(reason.size()), reason.data());
    std::abort();
}

[[noreturn]] void seastar::on_internal_error(seastar::logger&, std::exception_ptr ex) {
    try { std::rethrow_exception(ex); }
    catch (const std::exception& e) { fprintf(stderr, "FATAL: %s\n", e.what()); }
    catch (...) { fprintf(stderr, "FATAL: unknown exception\n"); }
    std::abort();
}

void seastar::on_internal_error_noexcept(seastar::logger&, std::string_view reason) noexcept {
    fprintf(stderr, "ERROR: %.*s\n", static_cast<int>(reason.size()), reason.data());
}

[[noreturn]] void seastar::on_fatal_internal_error(seastar::logger&, std::string_view reason) noexcept {
    fprintf(stderr, "FATAL: %.*s\n", static_cast<int>(reason.size()), reason.data());
    std::abort();
}

bool seastar::set_abort_on_internal_error(bool) noexcept { return true; }

namespace seastar::internal {
thread_local uint64_t internal_errors = 0;
}

// ---------------------------------------------------------------------------
// seastar::internal sstring helpers (seastar/src/core/sstring.cc)
// ---------------------------------------------------------------------------

namespace seastar::internal {

[[noreturn]] void throw_sstring_overflow() {
    throw std::length_error("sstring overflow");
}

[[noreturn]] void throw_bad_alloc() {
    throw std::bad_alloc();
}

} // namespace seastar::internal

// assert_fail is provided by seastar/src/util/log.cc

// ---------------------------------------------------------------------------
// seastar::timer stubs (we don't compile seastar/src/core/timer.cc)
// ---------------------------------------------------------------------------

#include <seastar/core/timer.hh>

namespace seastar {

template<typename Clock>
timer<Clock>::~timer() {}

template<typename Clock>
void timer<Clock>::arm(time_point tp, std::optional<duration> period) noexcept {}

template<typename Clock>
bool timer<Clock>::cancel() noexcept { return false; }

template class timer<std::chrono::steady_clock>;

} // namespace seastar

// ---------------------------------------------------------------------------
// seastar::smp stubs (helpers.cc needs these for invoke_abortable_on)
// These are called at runtime only if invoke_abortable_on is used,
// which our trace tests do NOT use. Provide no-op stubs.
// ---------------------------------------------------------------------------

#include <seastar/core/smp.hh>

namespace seastar {

void smp_message_queue::submit_item(unsigned, smp_timeout_clock::time_point,
                                     std::unique_ptr<work_item>) {
    fprintf(stderr, "STUB: smp_message_queue::submit_item called — not supported in trace tests\n");
    std::abort();
}

void smp_message_queue::respond(work_item*) {
    fprintf(stderr, "STUB: smp_message_queue::respond called — not supported in trace tests\n");
    std::abort();
}

// Static/thread-local members
thread_local smp_message_queue** smp::_qs = nullptr;
unsigned smp::count = 1;

} // namespace seastar

// ---------------------------------------------------------------------------
// utils::error_injection (stub for link)
// ---------------------------------------------------------------------------

#include "utils/error_injection.hh"

namespace utils {
template<> thread_local error_injection<false> error_injection<false>::_local{};
}

// NOTE: raft::logger is defined in raft/raft.cc -- do NOT define it here.

// ---------------------------------------------------------------------------
// seastar::testing stubs
// ---------------------------------------------------------------------------

#include <random>

namespace seastar::testing {
thread_local std::default_random_engine local_random_engine{42};
}

// seastar::schedule and reactor stubs (from future.cc)
#include <seastar/core/scheduling.hh>

namespace seastar {
void schedule(task*) noexcept {}
void report_exception(std::string_view, std::exception_ptr) {}
}

// reactor::exit stub - provide mangled symbol directly
namespace seastar {
class reactor;
[[noreturn]] void _reactor_exit_stub(int) { std::abort(); }
}

// free_sized (C23, not in all libc versions)
extern "C" void free_sized(void* p, size_t) { std::free(p); }
