#include "config.h"
#include "http_gateway.h"

#include <cstdio>
#include <string>
#include <utility>

int main(int argc, char **argv) {
  constexpr int kExitUsage = 2;
  constexpr int kExitConfiguration = 3;

  whisper_gateway::Config config;
  std::string error;
  if (!whisper_gateway::parse_args(argc, argv, &config, &error)) {
    std::fprintf(stderr, "错误：%s\n", error.c_str());
    whisper_gateway::print_help(argv[0]);
    return kExitUsage;
  }
  whisper_gateway::HttpGateway gateway(std::move(config));
  if (!gateway.validate_startup(&error)) {
    std::fprintf(stderr, "错误：%s\n", error.c_str());
    return kExitConfiguration;
  }
  return gateway.run();
}
