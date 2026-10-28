set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CMAKE_C_COMPILER "$ENV{MONO_RETRO_CC}")
if(NOT CMAKE_C_COMPILER)
    set(CMAKE_C_COMPILER aarch64-unknown-linux-gnu-gcc)
endif()
string(REGEX REPLACE "gcc$" "g++" CMAKE_CXX_COMPILER "${CMAKE_C_COMPILER}")
set(CMAKE_C_FLAGS_INIT "-O2 -mcpu=cortex-a55")
set(CMAKE_CXX_FLAGS_INIT "-O2 -mcpu=cortex-a55")

# The installed core uses Gentoo's loader and libraries, never Nix store paths.
set(CMAKE_SKIP_RPATH TRUE)
