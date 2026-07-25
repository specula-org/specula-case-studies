// SPDX-License-Identifier: Apache-2.0
// Inline instrumentation helpers for vbt::cuda::Allocator.  Included from
// allocator.cc after Allocator is fully visible.  All helpers are no-ops
// unless VBT_TRACE is defined.
//
// Usage pattern at a trace site (inside an Allocator member function, while
// holding `mu_`):
//
//   #if defined(VBT_TRACE) && VBT_TRACE
//     VBT_TRACE_BEGIN("raw_alloc.new");
//   #endif
//   ... real work ...
//   #if defined(VBT_TRACE) && VBT_TRACE
//     VBT_TRACE_MARK_END();
//     VBT_TRACE_CAPTURE_STATE(__state);   // expands to local std::ostringstream
//     std::ostringstream __fields;
//     __fields << "\"bid\":" << ::vbt_trace::register_block(b)
//              << ",\"sid\":\"s" << ::vbt_trace::stream_id_of(sid) << "\""
//              << ",\"size\":" << rounded;
//     VBT_TRACE_EMIT(__state, __fields);
//   #endif
//
// These expand to no-ops when VBT_TRACE is not defined, so the same source
// lines can compile in vanilla upstream builds.
#pragma once

#if defined(VBT_TRACE) && VBT_TRACE

#include "vbt_trace.h"
#include <sstream>

// A timebox variable; each trace site declares its own via VBT_TRACE_BEGIN.
#define VBT_TRACE_BEGIN(name)   auto __vbt_tb = ::vbt_trace::begin(name)
#define VBT_TRACE_MARK_END()    __vbt_tb.mark_end()

// Format allocator private state into a local std::ostringstream named `oss`.
// Caller must be inside an Allocator member function with access to `this`.
// Requires `by_ptr_`, `active_blocks_`, `deferred_`, `limbo_`, `stats_`,
// `routing_active_flag_`, `per_stream_free_`, `cross_stream_free_` to be
// visible.  See instrumentation-spec.md § 1 for field semantics.
#define VBT_TRACE_CAPTURE_STATE(oss)                                    \
    std::ostringstream oss;                                             \
    do {                                                                \
        auto __fmt_ids_from_blocks = [&](auto&& container) {            \
            oss << "[";                                                 \
            bool __first = true;                                        \
            for (auto* __b : container) {                               \
                int __id = ::vbt_trace::block_id_of(__b);               \
                if (__id <= 0) continue;                                \
                if (!__first) oss << ",";                               \
                oss << __id;                                            \
                __first = false;                                        \
            }                                                           \
            oss << "]";                                                 \
        };                                                              \
        oss << "\"existingBlockIds\":[";                                \
        { bool __first = true;                                          \
          for (const auto& __kv : this->by_ptr_) {                      \
              int __id = ::vbt_trace::block_id_of(__kv.second);         \
              if (__id <= 0) continue;                                  \
              if (!__first) oss << ",";                                 \
              oss << __id;                                              \
              __first = false;                                          \
          } }                                                           \
        oss << "],";                                                    \
        oss << "\"activeBlockIds\":";                                   \
        __fmt_ids_from_blocks(this->active_blocks_);                    \
        oss << ",\"perStreamFree\":{";                                  \
        { bool __first = true;                                          \
          for (const auto& __kv : this->per_stream_free_) {             \
              int __sid = ::vbt_trace::stream_id_of(__kv.first);        \
              if (!__first) oss << ",";                                 \
              oss << "\"s" << __sid << "\":";                           \
              __fmt_ids_from_blocks(__kv.second);                       \
              __first = false;                                          \
          } }                                                           \
        oss << "},";                                                    \
        oss << "\"crossStreamFree\":";                                  \
        __fmt_ids_from_blocks(this->cross_stream_free_);                \
        oss << ",\"deferredLen\":" << this->deferred_.size();           \
        oss << ",\"limboLens\":{";                                      \
        { bool __first = true;                                          \
          for (const auto& __kv : this->limbo_) {                       \
              int __sid = ::vbt_trace::stream_id_of(__kv.first);        \
              if (!__first) oss << ",";                                 \
              oss << "\"s" << __sid << "\":" << __kv.second.size();     \
              __first = false;                                          \
          } }                                                           \
        oss << "}";                                                     \
        oss << ",\"reservedBytes\":"                                    \
            << this->stats_.reserved_bytes_all_current;                 \
        oss << ",\"routingFlag\":"                                      \
            << (this->routing_active_flag_.load(                        \
                    std::memory_order_relaxed) ? "true" : "false");     \
        oss << ",\"tlsActive\":" << "false";                            \
        oss << ",\"tlsPool\":" << 0;                                    \
        oss << ",\"rdOutcome\":\"\"";                                   \
    } while (0)

#define VBT_TRACE_EMIT(state_oss, fields_oss)                           \
    ::vbt_trace::emit_line(__vbt_tb,                                    \
                           (state_oss).str().c_str(),                   \
                           (fields_oss).str().c_str())

#else  // !VBT_TRACE

#define VBT_TRACE_BEGIN(name)                ((void)0)
#define VBT_TRACE_MARK_END()                 ((void)0)
#define VBT_TRACE_CAPTURE_STATE(oss)         std::ostringstream oss
#define VBT_TRACE_EMIT(state_oss, fields)    ((void)0)

#endif  // VBT_TRACE
