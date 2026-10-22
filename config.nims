import std/os
switch("path", thisDir() / "src")
switch("define", "release")
switch("define", "useCpu")
switch("define", "windyBackends=" & getEnv("MONO_RETRO_BACKENDS", "x11"))
if getEnv("MONO_RETRO_TARGET") == "arm64":
  switch("cpu", "arm64")
  switch("gcc.exe", getEnv("MONO_RETRO_CC", "aarch64-unknown-linux-gnu-gcc"))
  switch("gcc.linkerexe", getEnv("MONO_RETRO_CC", "aarch64-unknown-linux-gnu-gcc"))
  switch("passL", "-Wl,--dynamic-linker=/lib/ld-linux-aarch64.so.1")
  switch("passL", "-L" & (thisDir() / "build/arm64-libs"))
