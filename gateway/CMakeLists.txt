cmake_minimum_required(VERSION 3.20)

project(whisper_on_demand_gateway LANGUAGES CXX)

include(CTest)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
# Keep the exact C++17 command lines available to editor tooling.  The gateway
# has a separate CMake source directory, so the repository-wide whisper.cpp
# database cannot describe its includes or language standard.
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(GATEWAY_HTTPLIB_INCLUDE "" CACHE PATH
    "Directory containing the pinned whisper.cpp httplib.h")
option(GATEWAY_ENABLE_SANITIZERS "Enable AddressSanitizer and UBSan" OFF)

if(NOT EXISTS "${GATEWAY_HTTPLIB_INCLUDE}/httplib.h")
  message(FATAL_ERROR
          "GATEWAY_HTTPLIB_INCLUDE must point to the pinned httplib.h directory")
endif()

# v1.9.2 exposes ContentReader(ContentReceiver) publicly, but its server-side
# implementation still routes that overload through the multipart parser when
# the original request is multipart.  Generate a build-local compatibility
# header that makes the public one-argument overload genuinely raw.  The
# pinned source header remains untouched and is blob-verified by the build
# script before CMake runs.
file(READ "${GATEWAY_HTTPLIB_INCLUDE}/httplib.h" GATEWAY_HTTPLIB_TEXT)
set(GATEWAY_HTTPLIB_ORIGINAL "${GATEWAY_HTTPLIB_TEXT}")
string(REPLACE
[[                         MultipartContentHeader multipart_header,
                         ContentReceiver multipart_receiver) const;]]
[[                         MultipartContentHeader multipart_header,
                         ContentReceiver multipart_receiver,
                         bool force_regular = false) const;]]
GATEWAY_HTTPLIB_TEXT "${GATEWAY_HTTPLIB_TEXT}")
string(REPLACE
[[  return read_content_core(strm, req, res, std::move(receiver),
                           std::move(multipart_header),
                           std::move(multipart_receiver));]]
[[  const bool force_regular = static_cast<bool>(receiver);
  return read_content_core(strm, req, res, std::move(receiver),
                           std::move(multipart_header),
                           std::move(multipart_receiver), force_regular);]]
GATEWAY_HTTPLIB_TEXT "${GATEWAY_HTTPLIB_TEXT}")
string(REPLACE
[[                          MultipartContentHeader multipart_header,
                          ContentReceiver multipart_receiver) const {]]
[[                          MultipartContentHeader multipart_header,
                          ContentReceiver multipart_receiver,
                          const bool force_regular) const {]]
GATEWAY_HTTPLIB_TEXT "${GATEWAY_HTTPLIB_TEXT}")
string(REPLACE
[[  if (req.is_multipart_form_data()) {]]
[[  if (!force_regular && req.is_multipart_form_data()) {]]
GATEWAY_HTTPLIB_TEXT "${GATEWAY_HTTPLIB_TEXT}")
if(GATEWAY_HTTPLIB_TEXT STREQUAL GATEWAY_HTTPLIB_ORIGINAL OR
   NOT GATEWAY_HTTPLIB_TEXT MATCHES "force_regular")
  message(FATAL_ERROR "Pinned httplib.h raw-reader compatibility patch did not apply")
endif()
set(GATEWAY_GENERATED_INCLUDE "${CMAKE_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GATEWAY_GENERATED_INCLUDE}")
file(WRITE "${GATEWAY_GENERATED_INCLUDE}/httplib.h" "${GATEWAY_HTTPLIB_TEXT}")

set(GATEWAY_WARNING_FLAGS
    -Wall
    -Wextra
    -Wpedantic
    -Wconversion
    -Wsign-conversion
    -Wshadow
    -Werror)

function(gateway_configure_target target)
  target_compile_options(${target} PRIVATE ${GATEWAY_WARNING_FLAGS})
  target_include_directories(${target} PRIVATE
      "${GATEWAY_GENERATED_INCLUDE}"
      "${CMAKE_CURRENT_SOURCE_DIR}"
      "${GATEWAY_HTTPLIB_INCLUDE}")
  if(GATEWAY_ENABLE_SANITIZERS)
    target_compile_options(${target} PRIVATE
        -fsanitize=address,undefined
        -fno-omit-frame-pointer)
    target_link_options(${target} PRIVATE -fsanitize=address,undefined)
  endif()
endfunction()

add_library(gateway_core STATIC
    backend_controller.cpp
    config.cpp
    http_gateway.cpp
    platform_process.cpp
    support.cpp)
gateway_configure_target(gateway_core)

add_executable(whisper-on-demand-gateway main.cpp)
gateway_configure_target(whisper-on-demand-gateway)
target_link_libraries(whisper-on-demand-gateway PRIVATE gateway_core)
set_target_properties(whisper-on-demand-gateway PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

if(BUILD_TESTING)
  add_executable(config-unit ../tests/config-unit.cpp config.cpp)
  gateway_configure_target(config-unit)
  add_test(NAME config-unit COMMAND config-unit)

  add_executable(support-unit ../tests/support-unit.cpp support.cpp)
  gateway_configure_target(support-unit)
  target_compile_options(support-unit PRIVATE -UNDEBUG)
  add_test(NAME support-unit COMMAND support-unit)

  add_executable(platform-process-unit
      ../tests/platform-process-unit.cpp
      config.cpp
      platform_process.cpp
      support.cpp)
  gateway_configure_target(platform-process-unit)
  add_test(NAME platform-process-unit COMMAND platform-process-unit)
endif()
