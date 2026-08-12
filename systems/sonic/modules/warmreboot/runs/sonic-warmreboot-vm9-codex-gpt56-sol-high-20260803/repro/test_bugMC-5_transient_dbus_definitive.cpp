#include <google/protobuf/util/json_util.h>

#include <chrono>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include "dbconnector.h"
#include "notificationconsumer.h"
#include "notificationproducer.h"
#include "reboot_common.h"
#include "reboot_interfaces.h"
#include "rebootbe.h"
#include "select.h"
#include "status_code_util.h"
#include "system/system.pb.h"

namespace {

using rebootbackend::RebootBE;

class OneTransientTransportFailure final : public DbusInterface {
 public:
  DbusResponse Reboot(const std::string&) override {
    ++reboot_calls;
    if (reboot_calls == 1) {
      // This is the exact result emitted by HostServiceDbus::Reboot when
      // issue_reboot throws DBus::Error (interfaces.cpp:35-40).
      return {DbusStatus::DBUS_FAIL,
              "HostServiceDbus::Reboot: failed to call reboot host service"};
    }
    return {DbusStatus::DBUS_SUCCESS, ""};
  }

  DbusResponse RebootStatus(const std::string&) override {
    return {DbusStatus::DBUS_SUCCESS, "{}"};
  }

  int reboot_calls = 0;
};

struct WireResponse {
  std::string op;
  std::string status;
  std::string message;
};

void Send(swss::NotificationProducer& producer, const std::string& op,
          const std::string& message) {
  std::vector<swss::FieldValueTuple> values{
      swss::FieldValueTuple{rebootbackend::DATA_TUPLE_KEY, message}};
  producer.send(op, "StatusCode", values);
}

bool Receive(swss::NotificationConsumer& consumer, WireResponse* response) {
  swss::Select select;
  select.addSelectable(&consumer);
  swss::Selectable* selected = nullptr;
  if (select.select(&selected, 5000) != swss::Select::OBJECT ||
      selected != &consumer) {
    return false;
  }

  std::vector<swss::FieldValueTuple> values;
  consumer.pop(response->op, response->status, values);
  for (const auto& value : values) {
    if (fvField(value) == rebootbackend::DATA_TUPLE_KEY) {
      response->message = fvValue(value);
    }
  }
  return true;
}

bool ReadSettledStatus(swss::NotificationProducer& producer,
                       swss::NotificationConsumer& consumer,
                       gnoi::system::RebootStatusResponse* status) {
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(5);
  while (std::chrono::steady_clock::now() < deadline) {
    Send(producer, rebootbackend::REBOOT_STATUS_KEY, "{}");
    WireResponse wire;
    if (!Receive(consumer, &wire)) return false;
    if (wire.op != rebootbackend::REBOOT_STATUS_KEY ||
        wire.status !=
            swss::statusCodeToStr(swss::StatusCode::SWSS_RC_SUCCESS)) {
      return false;
    }
    status->Clear();
    if (!google::protobuf::util::JsonStringToMessage(wire.message, status)
             .ok()) {
      return false;
    }
    if (!status->active()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
  return false;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::cerr << "usage: " << argv[0] << " DATABASE_CONFIG_JSON\n";
    return 2;
  }
  swss::SonicDBConfig::initialize(argv[1]);

  OneTransientTransportFailure dbus;
  RebootBE backend(dbus);
  swss::DBConnector state_db("STATE_DB", 0);
  swss::NotificationProducer requests(
      &state_db, rebootbackend::REBOOT_REQUEST_NOTIFICATION_CHANNEL);
  swss::NotificationConsumer responses(
      &state_db, rebootbackend::REBOOT_RESPONSE_NOTIFICATION_CHANNEL);

  std::thread backend_thread(&RebootBE::Start, &backend);
  std::this_thread::sleep_for(std::chrono::milliseconds(100));

  int failures = 0;
  const std::string warm_request =
      R"({"method":"WARM","message":"MC-5 transport-loss retry"})";

  Send(requests, rebootbackend::REBOOT_KEY, warm_request);
  WireResponse first;
  if (!Receive(responses, &first)) {
    std::cerr << "FAIL: no response to first public warm-reboot request\n";
    ++failures;
  } else {
    std::cout << "first_request_status=" << first.status << "\n";
  }

  gnoi::system::RebootStatusResponse first_status;
  if (!ReadSettledStatus(requests, responses, &first_status)) {
    std::cerr << "FAIL: first reboot status did not settle\n";
    ++failures;
  } else {
    std::cout << "after_transport_loss.active="
              << (first_status.active() ? "true" : "false") << "\n";
    std::cout << "after_transport_loss.class="
              << gnoi::system::RebootStatus_Status_Name(
                     first_status.status().status())
              << "\n";
    std::cout << "after_transport_loss.message="
              << first_status.status().message() << "\n";
    if (first_status.status().status() !=
        gnoi::system::RebootStatus_Status::
            RebootStatus_Status_STATUS_FAILURE) {
      std::cerr << "FAIL: transport uncertainty was not marked definitive\n";
      ++failures;
    }
  }

  Send(requests, rebootbackend::REBOOT_KEY, warm_request);
  WireResponse retry;
  if (!Receive(responses, &retry)) {
    std::cerr << "FAIL: no response to retry\n";
    ++failures;
  } else {
    std::cout << "retry_request_status=" << retry.status << "\n";
    std::cout << "retry_request_message=" << retry.message << "\n";
    if (retry.status != swss::statusCodeToStr(
                            swss::StatusCode::SWSS_RC_FAILED_PRECONDITION)) {
      std::cerr << "FAIL: public warm-reboot retry was not blocked\n";
      ++failures;
    }
  }

  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  gnoi::system::RebootStatusResponse later_status;
  if (!ReadSettledStatus(requests, responses, &later_status)) {
    std::cerr << "FAIL: later status query failed\n";
    ++failures;
  } else {
    std::cout << "later_status_class="
              << gnoi::system::RebootStatus_Status_Name(
                     later_status.status().status())
              << "\n";
    if (later_status.status().status() !=
        gnoi::system::RebootStatus_Status::
            RebootStatus_Status_STATUS_FAILURE) {
      std::cerr << "FAIL: downstream logic unexpectedly reconciled status\n";
      ++failures;
    }
  }

  std::cout << "dbus_reboot_calls=" << dbus.reboot_calls << "\n";
  if (dbus.reboot_calls != 1) {
    std::cerr << "FAIL: retry reached D-Bus instead of being rejected\n";
    ++failures;
  }

  backend.Stop();
  backend_thread.join();

  if (failures == 0) {
    std::cout << "BUG_REPRODUCED: transient D-Bus loss became permanent "
                 "FAILURE and blocked the next normal warm reboot\n";
    return 0;
  }
  return 1;
}
