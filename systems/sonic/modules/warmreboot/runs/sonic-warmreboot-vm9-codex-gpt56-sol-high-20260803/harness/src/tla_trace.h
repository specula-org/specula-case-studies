#pragma once

#include <string>

namespace rebootbackend {
namespace tla_trace {

void Emit(const std::string& name, const std::string& observed_json,
          const std::string& asic = "", const std::string& component = "");
std::string Quote(const std::string& value);

}  // namespace tla_trace
}  // namespace rebootbackend
