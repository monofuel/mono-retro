import std/[os, strutils]

let
  testBuild = relativePath(projectPath(), thisDir()).startsWith("tests" & DirSep)
  debugBuild = defined(debug) or (testBuild and not defined(danger))

if debugBuild:
  switch("define", "debug")
  switch("undef", "release")
  switch("undef", "danger")
  for option in ["boundChecks", "rangeChecks", "overflowChecks", "objChecks",
      "fieldChecks", "assertions", "stackTrace", "lineTrace"]:
    switch(option, "on")
else:
  # Define release explicitly for dependencies when selecting danger in NimScript.
  switch("define", "release")
  switch("define", "danger")

switch("path", thisDir() / "src")
let windySource = getEnv("MONO_RETRO_WINDY")
if windySource.len > 0:
  switch("path", windySource / "src")
switch("define", "useCpu")
switch("define", "ssl")
switch("define", "windyBackends=" & getEnv("MONO_RETRO_BACKENDS", "x11"))
if getEnv("MONO_RETRO_TARGET") == "arm64":
  switch("cpu", "arm64")
  switch("gcc.exe", getEnv("MONO_RETRO_CC", "aarch64-unknown-linux-gnu-gcc"))
  switch("gcc.linkerexe", getEnv("MONO_RETRO_CC", "aarch64-unknown-linux-gnu-gcc"))
  switch("passL", "-Wl,--dynamic-linker=/lib/ld-linux-aarch64.so.1")
  switch("passL", "-L" & (thisDir() / "build/arm64-libs"))
  switch("passL", "-Wl,-rpath-link," & (thisDir() / "build/arm64-libs"))
