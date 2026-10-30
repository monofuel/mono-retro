import std/os

const
  RaVendorRoot* = currentSourcePath.parentDir / "../../third_party/rcheevos"
  RaVersion* = "12.5.0"

{.passC: "-I" & RaVendorRoot.parentDir & " -I" & (RaVendorRoot / "include") &
  " -I" & (RaVendorRoot / "src").}
{.passC: "-DRC_CLIENT_SUPPORTS_HASH -DRC_HASH_NO_DISC -DRC_HASH_NO_ZIP -DRC_HASH_NO_ENCRYPTED".}
{.passL: "-lm -pthread".}

{.compile: RaVendorRoot / "src/rc_client.c".}
{.compile: RaVendorRoot / "src/rc_compat.c".}
{.compile: RaVendorRoot / "src/rc_util.c".}
{.compile: RaVendorRoot / "src/rc_version.c".}
{.compile: RaVendorRoot / "src/rc_libretro.c".}
{.compile: RaVendorRoot / "src/rapi/rc_api_common.c".}
{.compile: RaVendorRoot / "src/rapi/rc_api_user.c".}
{.compile: RaVendorRoot / "src/rapi/rc_api_runtime.c".}
{.compile: RaVendorRoot / "src/rapi/rc_api_info.c".}
{.compile: RaVendorRoot / "src/rhash/hash.c".}
{.compile: RaVendorRoot / "src/rhash/hash_rom.c".}
{.compile: RaVendorRoot / "src/rhash/md5.c".}
{.compile: RaVendorRoot / "src/rcheevos/alloc.c".}
{.compile: RaVendorRoot / "src/rcheevos/condition.c".}
{.compile: RaVendorRoot / "src/rcheevos/condset.c".}
{.compile: RaVendorRoot / "src/rcheevos/consoleinfo.c".}
{.compile: RaVendorRoot / "src/rcheevos/format.c".}
{.compile: RaVendorRoot / "src/rcheevos/lboard.c".}
{.compile: RaVendorRoot / "src/rcheevos/memref.c".}
{.compile: RaVendorRoot / "src/rcheevos/operand.c".}
{.compile: RaVendorRoot / "src/rcheevos/richpresence.c".}
{.compile: RaVendorRoot / "src/rcheevos/runtime.c".}
{.compile: RaVendorRoot / "src/rcheevos/runtime_progress.c".}
{.compile: RaVendorRoot / "src/rcheevos/trigger.c".}
{.compile: RaVendorRoot / "src/rcheevos/value.c".}
