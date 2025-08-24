cmake_minimum_required(VERSION 3.14)

# Project-level configuration for the CMake part of the build.
set(PROJECT_NAME "flutter_nnnoiseless")
project(${PROJECT_NAME} LANGUAGES CXX)

# Include the cargokit build script helper.
include("../cargokit/cmake/cargokit.cmake")

# Use a conditional to prevent the target from being created more than once.
if(NOT TARGET ${PROJECT_NAME}_cargokit)
    # This command creates the library target.
    # The first argument is the CMake target, the third is the Rust library name.
    apply_cargokit(${PROJECT_NAME} ../rust rust_lib_flutter_nnnoiseless "")
endif()

# This variable is required by the Flutter tool. It tells it which library to
# bundle with the app. We get the path from the cargokit script output.
set(flutter_nnnoiseless_bundled_libraries
        "${${PROJECT_NAME}_cargokit_lib}"
        PARENT_SCOPE
)
