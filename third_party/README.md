# libretro API header

`libretro.h` is the unmodified public API header from
[libretro/RetroArch](https://github.com/libretro/RetroArch/blob/c0d33c5f176f31ab23be98d7ea4a985e8a10c2da/libretro.h),
pinned to commit `c0d33c5f176f31ab23be98d7ea4a985e8a10c2da`.

SHA-256: `7d59471531b80120d7caf5071273b24e1f2e81945d9565e27acb94854f978acc`.

The header is MIT licensed; its copyright and license notice remain intact.
The player binds only the ABI it needs. The small C logging bridge handles
the API's variadic log callback without implementing variadic formatting in Nim.
The independent C fixture checks these bindings against the same public header.

No RetroArch frontend implementation, emulator core, ROM or save is vendored.
mGBA is a separately obtained runtime library under MPL-2.0; its license and
corresponding source obligations apply separately if distributing that core.
