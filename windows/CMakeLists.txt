cmake_minimum_required(VERSION 3.14)

# Project-level configuration for the CMake part of the build.
set(PROJECT_NAME "flutter_nnnoiseless")
project(${PROJECT_NAME} LANGUAGES CXX)

# Define the actual name of the Rust library crate that will be built.
set(RUST_LIB_NAME "rust_lib_flutter_nnnoiseless")

# Define the final name of the DLL that the Flutter app will load.
set(FINAL_DLL_NAME "flutter_nnnoiseless.dll")

# Define the final output directory for the DLL, which is next to the app's executable.
# The $<CONFIG> part is a generator expression that correctly resolves to "Debug", "Release", etc.
set(FINAL_DESTINATION "${CMAKE_BINARY_DIR}/runner/$<CONFIG>")

# Include the cargokit build script helper.
include("../cargokit/cmake/cargokit.cmake")

# Use a conditional to prevent the target from being created more than once.
if(NOT TARGET ${PROJECT_NAME}_cargokit)
    # This command creates the library target.
    # The first argument is the CMake target, the third is the Rust library name.
    apply_cargokit(${PROJECT_NAME} ../rust ${RUST_LIB_NAME} "")
endif()

# This variable is required by the Flutter tool. It tells it which library to
# bundle with the app. We point it to the final, renamed DLL.
set(flutter_nnnoiseless_bundled_libraries
        "${FINAL_DESTINATION}/${FINAL_DLL_NAME}"
        PARENT_SCOPE
)

# This command runs immediately after the Rust library is built.
# This is the most reliable way to solve the "first build" race condition,
# as it ensures the copy only happens after the source file exists.
add_custom_command(
        TARGET ${PROJECT_NAME}_cargokit POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${${PROJECT_NAME}_cargokit_lib}"
        "${FINAL_DESTINATION}/${FINAL_DLL_NAME}"
        COMMENT "Copying and renaming Rust library to final destination"
)
