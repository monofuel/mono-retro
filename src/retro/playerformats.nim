const
  MonoRetroSetPixelFormat* = 0x20000'u32 or 0x4d52'u32
    ## Private environment request with a uint32 pixel-format payload.
  MonoRetroXbgr8888* = 0x34324258'u32
    ## Opaque little-endian XBGR8888: bytes R, G, B, 0xff. See include/mono_retro_libretro.h.
