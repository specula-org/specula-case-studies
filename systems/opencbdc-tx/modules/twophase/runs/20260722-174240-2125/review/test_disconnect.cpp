#include "util/serialization/format.hpp"
#include "util/rpc/async_server.hpp"
#include "util/rpc/tcp_client.hpp"
#include "util/rpc/tcp_server.hpp"

#include <chrono>
#include <cstdint>
#include <future>
#include <iostream>
#include <memory>

int main() {
    using namespace std::chrono_literals;
    using request = std::int64_t;
    using response = std::int64_t;

    const auto endpoint
        = cbdc::network::endpoint_t{cbdc::network::localhost, 45679};
    auto accepted = std::promise<void>();
    auto accepted_future = accepted.get_future();

    auto server
        = std::make_unique<cbdc::rpc::async_tcp_server<request, response>>(
            endpoint);
    server->register_handler_callback(
        [&](request, std::function<void(std::optional<response>)>) {
            accepted.set_value();
            return true;
        });
    if(!server->init()) {
        std::cerr << "server init failed\n";
        return 2;
    }

    auto client
        = std::make_unique<cbdc::rpc::tcp_client<request, response>>(
            std::vector<cbdc::network::endpoint_t>{endpoint});
    if(!client->init()) {
        std::cerr << "client init failed\n";
        return 3;
    }

    auto result = std::promise<std::optional<response>>();
    auto result_future = result.get_future();
    if(!client->call(42, [&](std::optional<response> value) {
           result.set_value(std::move(value));
       })) {
        std::cerr << "request send failed\n";
        return 4;
    }

    if(accepted_future.wait_for(1s) != std::future_status::ready) {
        std::cerr << "server never accepted request\n";
        return 5;
    }

    server.reset();
    const auto after_disconnect = result_future.wait_for(1s);
    const auto pending_after_disconnect
        = after_disconnect == std::future_status::timeout;
    std::cout << "pending_after_disconnect="
              << (pending_after_disconnect ? "true" : "false") << '\n';

    client.reset();
    const auto callback_after_client_destroy
        = result_future.wait_for(1s) == std::future_status::ready;
    std::cout << "callback_after_client_destroy="
              << (callback_after_client_destroy ? "true" : "false") << '\n';

    if(!pending_after_disconnect || callback_after_client_destroy) {
        return 1;
    }
    return 0;
}
