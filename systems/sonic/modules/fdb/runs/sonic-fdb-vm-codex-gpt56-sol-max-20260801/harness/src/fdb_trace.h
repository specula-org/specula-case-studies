#pragma once

#include <cstdint>
#include <string>

namespace fdb_trace
{

#ifdef FDB_TLA_TRACE

enum class NotificationKind
{
    Learn,
    Move,
    Aged,
};

// These hooks are observational.  They are enabled only when
// FDB_TLA_TRACE_FILE names an output file and never feed values back into the
// production decision path.
void receiveNotification(NotificationKind kind,
                         const std::string &realKey,
                         const std::string &realPort) noexcept;
void updateStart(const std::string &realKey) noexcept;
void ignoreAged(const std::string &realKey) noexcept;
void updateCounters(const std::string &realKey) noexcept;
void storeFdbEntryState(const std::string &realKey) noexcept;
void notifyObservers(const std::string &realKey) noexcept;

std::uint64_t flushRequest(bool byVlan,
                           const std::string &scope,
                           const std::string &realPort) noexcept;
void flushResult(std::uint64_t epoch, bool success) noexcept;

#else

enum class NotificationKind
{
    Learn,
    Move,
    Aged,
};

inline void receiveNotification(NotificationKind,
                                const std::string &,
                                const std::string &) noexcept
{
}

inline void updateStart(const std::string &) noexcept
{
}

inline void ignoreAged(const std::string &) noexcept
{
}

inline void updateCounters(const std::string &) noexcept
{
}

inline void storeFdbEntryState(const std::string &) noexcept
{
}

inline void notifyObservers(const std::string &) noexcept
{
}

inline std::uint64_t flushRequest(bool,
                                  const std::string &,
                                  const std::string &) noexcept
{
    return 0;
}

inline void flushResult(std::uint64_t, bool) noexcept
{
}

#endif

} // namespace fdb_trace
