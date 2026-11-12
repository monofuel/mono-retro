import
  std/os

{.passC: "-I" & currentSourcePath.parentDir / "../../third_party".}

type
  MicrophoneOpaque {.importc: "retro_microphone_t", header: "libretro.h", incompleteStruct.} = object
  ConstMicrophoneOpaque {.importc: "const retro_microphone_t", header: "libretro.h", incompleteStruct.} = object
  MicrophoneHandle* = ptr MicrophoneOpaque
  ConstMicrophoneHandle* = ptr ConstMicrophoneOpaque
  MicrophoneParams* {.bycopy, importc: "retro_microphone_params_t", header: "libretro.h".} = object
    rate*: cuint
  ConstMicrophoneParams* {.bycopy, importc: "const retro_microphone_params_t", header: "libretro.h".} = object
    rate*: cuint
  MicrophoneInterface* {.bycopy, importc: "struct retro_microphone_interface", header: "libretro.h".} = object
    version* {.importc: "interface_version".}: cuint
    open* {.importc: "open_mic".}: proc(params: ptr ConstMicrophoneParams): MicrophoneHandle {.cdecl.}
    close* {.importc: "close_mic".}: proc(handle: MicrophoneHandle) {.cdecl.}
    getParams* {.importc: "get_params".}: proc(handle: ConstMicrophoneHandle, params: ptr MicrophoneParams): bool {.cdecl.}
    setState* {.importc: "set_mic_state".}: proc(handle: MicrophoneHandle, enabled: bool): bool {.cdecl.}
    getState* {.importc: "get_mic_state".}: proc(handle: ConstMicrophoneHandle): bool {.cdecl.}
    read* {.importc: "read_mic".}: proc(handle: MicrophoneHandle, samples: ptr int16, count: csize_t): cint {.cdecl.}

const MicrophoneVersion* = 1.cuint

converter readOnly*(handle: MicrophoneHandle): ConstMicrophoneHandle =
  ## Preserve C const qualification for microphone query callbacks.
  cast[ConstMicrophoneHandle](handle)

converter readOnly*(params: ptr MicrophoneParams): ptr ConstMicrophoneParams =
  ## Pass mutable parameter storage to a callback that only reads it.
  cast[ptr ConstMicrophoneParams](params)
