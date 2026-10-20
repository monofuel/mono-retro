import std/os
switch("path", thisDir() / "src")
switch("define", "release")
if getEnv("MONO_RETRO_TARGET") == "arm64":
  switch("cpu", "arm64")
  switch("gcc.exe", getEnv("MONO_RETRO_CC", "aarch64-unknown-linux-gnu-gcc"))
  switch("gcc.linkerexe", getEnv("MONO_RETRO_CC", "aarch64-unknown-linux-gnu-gcc"))
  switch("passL", "-Wl,--dynamic-linker=/lib/ld-linux-aarch64.so.1")
