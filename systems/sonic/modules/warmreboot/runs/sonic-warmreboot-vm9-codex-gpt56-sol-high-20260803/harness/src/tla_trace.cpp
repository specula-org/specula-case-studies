#include "tla_trace.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>

namespace rebootbackend {
namespace tla_trace {
namespace {

std::atomic<unsigned long long> sequence{0};

unsigned long long MonotonicNs() {
  struct timespec ts {};
  clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
  return static_cast<unsigned long long>(ts.tv_sec) * 1000000000ULL +
         static_cast<unsigned long long>(ts.tv_nsec);
}

std::string ProcessInstance() {
  static const std::string instance = [] {
    const char* configured = std::getenv("SPECULA_PROCESS_INSTANCE");
    if (configured != nullptr && configured[0] != '\0') return std::string(configured);
    std::ostringstream out;
    out << getpid() << "-" << std::chrono::system_clock::now().time_since_epoch().count();
    return out.str();
  }();
  return instance;
}

}  // namespace

std::string Quote(const std::string& value) {
  std::ostringstream out;
  out << '"';
  for (const unsigned char ch : value) {
    switch (ch) {
      case '\\': out << "\\\\"; break;
      case '"': out << "\\\""; break;
      case '\n': out << "\\n"; break;
      case '\r': out << "\\r"; break;
      case '\t': out << "\\t"; break;
      default:
        if (ch < 0x20) {
          const char hex[] = "0123456789abcdef";
          out << "\\u00" << hex[(ch >> 4) & 0xf] << hex[ch & 0xf];
        } else {
          out << static_cast<char>(ch);
        }
    }
  }
  out << '"';
  return out.str();
}

void Emit(const std::string& name, const std::string& observed_json,
          const std::string& asic, const std::string& component) {
  const char* socket_path = std::getenv("SPECULA_TRACE_SOCKET");
  if (socket_path == nullptr || socket_path[0] == '\0') return;

  const unsigned long long monotonic_ns = MonotonicNs();
  const unsigned long long local_seq = ++sequence;
  std::ostringstream out;
  out << "{\"tag\":\"raw\",\"ts\":" << monotonic_ns
      << ",\"event\":{\"name\":" << Quote(name)
      << ",\"source\":\"rebootbackend\",\"process_instance\":"
      << Quote(ProcessInstance()) << ",\"local_seq\":" << local_seq
      << ",\"monotonic_ns\":" << monotonic_ns;
  if (!asic.empty()) out << ",\"asic\":" << Quote(asic);
  if (!component.empty()) out << ",\"component\":" << Quote(component);
  out << ",\"observed\":" << observed_json << "}}";
  const std::string payload = out.str();
  if (payload.size() > 60000) return;

  const int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return;
  struct sockaddr_un address {};
  address.sun_family = AF_UNIX;
  std::strncpy(address.sun_path, socket_path, sizeof(address.sun_path) - 1);
  (void)sendto(fd, payload.data(), payload.size(), 0,
               reinterpret_cast<struct sockaddr*>(&address), sizeof(address));
  close(fd);
}

}  // namespace tla_trace
}  // namespace rebootbackend
