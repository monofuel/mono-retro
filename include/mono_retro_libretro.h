#ifndef MONO_RETRO_LIBRETRO_H
#define MONO_RETRO_LIBRETRO_H

/* Private mono-retro extension; these are not enum retro_pixel_format values.
 * Call the environment callback with this command and a const uint32_t* payload.
 * A true result selects the requested format for subsequent video callbacks.
 * False leaves the previous format unchanged; the core may try standard
 * RETRO_ENVIRONMENT_SET_PIXEL_FORMAT with RETRO_PIXEL_FORMAT_XRGB8888.
 */
#define MONO_RETRO_ENVIRONMENT_SET_PIXEL_FORMAT (0x20000u | 0x4d52u)

/* Little-endian opaque XBGR8888: bytes R, G, B, 0xff.
 * The filler byte MUST be 0xff so the bytes are also valid opaque premultiplied
 * RGBA for Pixie. No channel swap or alpha normalization is performed by the
 * frontend. Big-endian hosts reject this private format.
 * Width, height, byte pitch and borrowed-buffer lifetime follow libretro's
 * normal video-refresh callback. Padding between rows is allowed.
 */
#define MONO_RETRO_PIXEL_FORMAT_XBGR8888 0x34324258u

#endif
