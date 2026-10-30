# Private libretro pixel format

This optional extension lets a cooperating software core send opaque Pixie
pixels without channel conversion. It does not modify libretro's public enum
or identify the frontend by name. The C constants are in
[`include/mono_retro_libretro.h`](../include/mono_retro_libretro.h); Nim constants
are in `src/retro/playerformats.nim`.

## Negotiation

During `retro_load_game`, before sending video, call the environment callback:

- Command: `MONO_RETRO_ENVIRONMENT_SET_PIXEL_FORMAT = 0x00024D52`
  (`RETRO_ENVIRONMENT_PRIVATE | 0x4D52`).
- Data: pointer to a native `uint32_t` containing
  `MONO_RETRO_PIXEL_FORMAT_XBGR8888 = 0x34324258` (FourCC `XB24`).
- `true`: subsequent software video callbacks use the private format.
- `false`: the previous format remains active, with no fatal error. Try the
  standard `RETRO_ENVIRONMENT_SET_PIXEL_FORMAT` command (`10`) with
  `RETRO_PIXEL_FORMAT_XRGB8888` (`1`). If that also fails, fail core startup.

Null payloads and unknown formats return false. Little-endian hosts accept
this format; big-endian hosts reject it. Do not pass the private FourCC through
standard `SET_PIXEL_FORMAT` or reuse an unassigned public enum number.
A later accepted standard format replaces the private format normally.

## Pixel contract

Each pixel is four bytes **R, G, B, 0xff**. Although XBGR's X component is normally
unused, **this private extension requires it to be 255**: these bytes must also be
valid opaque premultiplied RGBA for Pixie. The host does not swap channels,
normalize alpha, or scan pixels to enforce the opaque-byte requirement.
Transparent Pixie images must be composited onto an opaque background first.

Use the ordinary `retro_video_refresh_t` callback with the frame's actual width,
height and byte pitch. Padded rows are supported. The callback's input is borrowed;
the player copies rows into owned storage before returning so the core may reuse
its buffer. A null video pointer duplicates the previous frame as usual.
For dual-screen frames, keep the existing combined top/bottom geometry. Copying
opaque Pixie rows into a combined buffer requires no per-pixel conversion.

This removes channel-conversion passes; it does not promise zero-copy transport,
GPU rendering, a performance gain in every workload, or support in other hosts.
Standard XRGB8888, RGB565 and 0RGB1555 remain available without this extension.
