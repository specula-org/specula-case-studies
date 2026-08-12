#include <google/protobuf/util/json_util.h>
#include <gtest/gtest.h>

#include <chrono>
#include <condition_variable>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "notificationconsumer.h"
#include "notificationproducer.h"
#include "reboot_interfaces.h"
#include "rebootbe.h"
#include "select.h"
#include "status_code_util.h"
#include "system/system.pb.h"

namespace rebootbackend {
namespace {

// This fake implements the relevant behavior of the real public D-Bus peer at
// sonic-host-services/host_modules/reboot.py:199-251: an accepted operation
// remains active independently and a later issue_reboot is rejected.
class StatefulHostService final : public DbusInterface {
 public:
  DbusResponse Reboot(const std::string&) override {
    std::lock_guard<std::mutex> lock(mutex_);
    ++reboot_calls_;
    if (active_) {
      ++rejections_;
      changed_.notify_all();
      return {DbusStatus::DBUS_FAIL, "Previous reboot is ongoing"};
    }
    active_ = true;
    changed_.notify_all();
    return {DbusStatus::DBUS_SUCCESS, ""};
  }

  DbusResponse RebootStatus(const std::string&) override {
    std::lock_guard<std::mutex> lock(mutex_);
    ++status_calls_;
    return {DbusStatus::DBUS_SUCCESS,
            "{\"active\":true,\"when\":1,\"count\":1,"
            "\"method\":\"WARM\",\"status\":{}}"};
  }

  bool WaitForRebootCalls(int count) {
    std::unique_lock<std::mutex> lock(mutex_);
    return changed_.wait_for(lock, std::chrono::seconds(2),
                             [&] { return reboot_calls_ >= count; });
  }

  bool WaitForRejections(int count) {
    std::unique_lock<std::mutex> lock(mutex_);
    return changed_.wait_for(lock, std::chrono::seconds(2),
                             [&] { return rejections_ >= count; });
  }

  bool active() {
    std::lock_guard<std::mutex> lock(mutex_);
    return active_;
  }

  int reboot_calls() {
    std::lock_guard<std::mutex> lock(mutex_);
    return reboot_calls_;
  }

  int rejections() {
    std::lock_guard<std::mutex> lock(mutex_);
    return rejections_;
  }

  int status_calls() {
    std::lock_guard<std::mutex> lock(mutex_);
    return status_calls_;
  }

 private:
  std::mutex mutex_;
  std::condition_variable changed_;
  bool active_ = false;
  int reboot_calls_ = 0;
  int rejections_ = 0;
  int status_calls_ = 0;
};

struct ChannelResponse {
  std::string op;
  std::string code;
  std::string message;
};

class PublicRebootClient {
 public:
  PublicRebootClient()
      : db_("STATE_DB", 0),
        requests_(&db_, REBOOT_REQUEST_NOTIFICATION_CHANNEL),
        responses_(&db_, REBOOT_RESPONSE_NOTIFICATION_CHANNEL) {}

  ChannelResponse Call(const std::string& op, const std::string& json) {
    std::vector<swss::FieldValueTuple> values{
        swss::FieldValueTuple(DATA_TUPLE_KEY, json)};
    requests_.send(op, "", values);

    swss::Select select;
    select.addSelectable(&responses_);
    swss::Selectable* selected = nullptr;
    EXPECT_EQ(select.select(&selected, 2000), swss::Select::OBJECT);
    EXPECT_EQ(selected, &responses_);

    ChannelResponse result;
    std::vector<swss::FieldValueTuple> returned;
    responses_.pop(result.op, result.code, returned);
    for (const auto& field : returned) {
      if (fvField(field) == DATA_TUPLE_KEY) result.message = fvValue(field);
    }
    return result;
  }

 private:
  swss::DBConnector db_;
  swss::NotificationProducer requests_;
  swss::NotificationConsumer responses_;
};

class RunningBackend {
 public:
  explicit RunningBackend(DbusInterface& host) : backend_(host) {
    thread_ = std::thread(&RebootBE::Start, &backend_);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }

  ~RunningBackend() { Stop(); }

  void Stop() {
    if (thread_.joinable()) {
      backend_.Stop();
      thread_.join();
    }
  }

 private:
  RebootBE backend_;
  std::thread thread_;
};

TEST(MC1BackendRestartLosesAcceptedOwnership,
     Level0PublicNotificationChannels) {
  sigterm_requested = false;
  StatefulHostService host;
  PublicRebootClient client;
  const std::string warm_request =
      "{\"method\":\"WARM\",\"message\":\"mc1-first\"}";

  {
    RunningBackend first_backend(host);
    const ChannelResponse first = client.Call(REBOOT_KEY, warm_request);
    ASSERT_EQ(first.op, REBOOT_KEY);
    ASSERT_EQ(first.code,
              swss::statusCodeToStr(swss::StatusCode::SWSS_RC_SUCCESS));
    ASSERT_TRUE(host.WaitForRebootCalls(1));
    ASSERT_TRUE(host.active());
    std::cout << "FIRST_REBOOT_RESPONSE=" << first.code
              << " HOST_ACTIVE=" << std::boolalpha << host.active() << '\n';

    // This stops/restarts only the backend process boundary. The separately
    // maintained host-service operation deliberately remains active.
    first_backend.Stop();
  }

  {
    RunningBackend restarted_backend(host);

    const ChannelResponse status = client.Call(REBOOT_STATUS_KEY, "{}");
    ASSERT_EQ(status.code,
              swss::statusCodeToStr(swss::StatusCode::SWSS_RC_SUCCESS));
    gnoi::system::RebootStatusResponse parsed_status;
    ASSERT_TRUE(google::protobuf::util::JsonStringToMessage(
                    status.message, &parsed_status)
                    .ok());

    std::cout << "AFTER_RESTART_STATUS_ACTIVE=" << std::boolalpha
              << parsed_status.active() << " HOST_ACTIVE=" << host.active()
              << " HOST_STATUS_CALLS=" << host.status_calls() << '\n';
    EXPECT_FALSE(parsed_status.active());
    EXPECT_TRUE(host.active());
    // A fresh non-HALT backend never reconciles status through the host API.
    EXPECT_EQ(host.status_calls(), 0);

    const ChannelResponse second = client.Call(REBOOT_KEY, warm_request);
    ASSERT_EQ(second.op, REBOOT_KEY);
    ASSERT_TRUE(host.WaitForRebootCalls(2));
    ASSERT_TRUE(host.WaitForRejections(1));

    std::cout << "SECOND_REBOOT_RESPONSE=" << second.code
              << " HOST_REJECTED=" << host.rejections()
              << " HOST_ACTIVE=" << host.active() << '\n';

    // The real gNOI server maps this SWSS success to an OK Reboot RPC even
    // though the real host-side ownership guard rejected the operation.
    EXPECT_EQ(second.code,
              swss::statusCodeToStr(swss::StatusCode::SWSS_RC_SUCCESS));
    EXPECT_EQ(host.rejections(), 1);
    EXPECT_TRUE(host.active());
  }
}

}  // namespace
}  // namespace rebootbackend
