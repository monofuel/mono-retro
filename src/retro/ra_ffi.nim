import ./ra_build
export ra_build

type
  RcClient* {.importc: "rc_client_t", header: "rc_client.h", incompleteStruct.} = object
  RcAsync* {.importc: "rc_client_async_handle_t", header: "rc_client.h", incompleteStruct.} = object
  RcConstString* {.importc: "const char*", header: "rc_client.h".} = distinct cstring
  RcRequest* {.importc: "const rc_api_request_t", header: "rc_api_request.h", bycopy.} = object
    url*: cstring
    postData* {.importc: "post_data".}: cstring
    contentType* {.importc: "content_type".}: cstring
  RcResponse* {.importc: "rc_api_server_response_t", header: "rc_api_request.h", bycopy.} = object
    body*: cstring
    bodyLength* {.importc: "body_length".}: csize_t
    httpStatus* {.importc: "http_status_code".}: cint
  RcUser* {.importc: "rc_client_user_t", header: "rc_client.h", bycopy.} = object
    username*, token*: cstring
  RcGame* {.importc: "rc_client_game_t", header: "rc_client.h", bycopy.} = object
    id*: uint32
    title*: cstring
  RcAchievement* {.importc: "rc_client_achievement_t", header: "rc_client.h", bycopy.} = object
    title*, description*: cstring
    measuredProgress* {.importc: "measured_progress".}: array[24, char]
    id*, points*: uint32
    state*, unlocked*: uint8
  RcBucket* {.importc: "rc_client_achievement_bucket_t", header: "rc_client.h", bycopy.} = object
    achievements*: ptr UncheckedArray[ptr RcAchievement]
    count* {.importc: "num_achievements".}: uint32
  RcAchievementList* {.importc: "rc_client_achievement_list_t", header: "rc_client.h", bycopy.} = object
    buckets*: ptr UncheckedArray[RcBucket]
    count* {.importc: "num_buckets".}: uint32
  RcSummary* {.importc: "rc_client_user_game_summary_t", header: "rc_client.h", bycopy.} = object
    total* {.importc: "num_core_achievements".}: uint32
    unlocked* {.importc: "num_unlocked_achievements".}: uint32
  RcEvent* {.importc: "const rc_client_event_t", header: "rc_client.h", bycopy.} = object
    `type`*: uint32
    achievement*: ptr RcAchievement
  RcMemoryInfo* {.importc: "rc_libretro_core_memory_info_t", header: "rc_libretro.h", bycopy.} = object
    data*: ptr uint8
    size*: csize_t
  RcRegions* {.importc: "rc_libretro_memory_regions_t", header: "rc_libretro.h", bycopy.} = object
    data*: array[32, ptr uint8]
    size*: array[32, csize_t]
    totalSize* {.importc: "total_size".}: csize_t
    count*: uint32
  RcMemoryRead* = proc(address: uint32, buffer: ptr uint8, count: uint32, client: ptr RcClient): uint32 {.cdecl.}
  RcServerCallback* {.importc: "rc_client_server_callback_t", header: "rc_client.h".} = proc(response: ptr RcResponse, userdata: pointer) {.cdecl.}
  RcServerCall* {.importc: "rc_client_server_call_t", header: "rc_client.h".} = proc(request: ptr RcRequest, callback: RcServerCallback, userdata: pointer, client: ptr RcClient) {.cdecl.}
  RcCallback* {.importc: "rc_client_callback_t", header: "rc_client.h".} = proc(code: cint, message: RcConstString, client: ptr RcClient, userdata: pointer) {.cdecl.}
  RcEventHandler* {.importc: "rc_client_event_handler_t", header: "rc_client.h".} = proc(event: ptr RcEvent, client: ptr RcClient) {.cdecl.}
  RcMemoryGetter* = proc(id: uint32, info: ptr RcMemoryInfo) {.cdecl.}

const
  RcOk* = 0.cint
  RcSnes* = 3'u32
  RcClientError* = -1.cint
  RcRetryableError* = -2.cint
  RcAchievementTriggered* = 1'u32
  RcServerError* = 16'u32
  RcDisconnected* = 17'u32
  RcReconnected* = 18'u32
  RcUnlocked* = 2'u8
  RcCategoryCore* = 1.cint
  RcGroupingLockState* = 0.cint

{.push cdecl, header: "rc_client.h".}
proc rcCreate*(memory: RcMemoryRead, server: RcServerCall): ptr RcClient {.importc: "rc_client_create".}
proc rcDestroy*(client: ptr RcClient) {.importc: "rc_client_destroy".}
proc rcSetUserdata*(client: ptr RcClient, userdata: pointer) {.importc: "rc_client_set_userdata".}
proc rcGetUserdata*(client: ptr RcClient): pointer {.importc: "rc_client_get_userdata".}
proc rcSetHardcore*(client: ptr RcClient, enabled: cint) {.importc: "rc_client_set_hardcore_enabled".}
proc rcSetBackgroundReads*(client: ptr RcClient, enabled: cint) {.importc: "rc_client_set_allow_background_memory_reads".}
proc rcSetEvents*(client: ptr RcClient, handler: RcEventHandler) {.importc: "rc_client_set_event_handler".}
proc rcLoginToken*(client: ptr RcClient, username, token: cstring, callback: RcCallback, userdata: pointer): ptr RcAsync {.importc: "rc_client_begin_login_with_token".}
proc rcLoginPassword*(client: ptr RcClient, username, password: cstring, callback: RcCallback, userdata: pointer): ptr RcAsync {.importc: "rc_client_begin_login_with_password".}
proc rcGetUser*(client: ptr RcClient): ptr RcUser {.importc: "rc_client_get_user_info".}
proc rcLoadGame*(client: ptr RcClient, console: uint32, path: cstring, data: ptr uint8, size: csize_t, callback: RcCallback, userdata: pointer): ptr RcAsync {.importc: "rc_client_begin_identify_and_load_game".}
proc rcGetGame*(client: ptr RcClient): ptr RcGame {.importc: "rc_client_get_game_info".}
proc rcUnload*(client: ptr RcClient) {.importc: "rc_client_unload_game".}
proc rcFrame*(client: ptr RcClient) {.importc: "rc_client_do_frame".}
proc rcIdle*(client: ptr RcClient) {.importc: "rc_client_idle".}
proc rcResetProgress*(client: ptr RcClient, data: ptr uint8, size: csize_t): cint {.importc: "rc_client_deserialize_progress_sized".}
proc rcSummary*(client: ptr RcClient, summary: ptr RcSummary) {.importc: "rc_client_get_user_game_summary".}
proc rcList*(client: ptr RcClient, category, grouping: cint): ptr RcAchievementList {.importc: "rc_client_create_achievement_list".}
proc rcDestroyList*(list: ptr RcAchievementList) {.importc: "rc_client_destroy_achievement_list".}
proc rcAchievement*(client: ptr RcClient, id: uint32): ptr RcAchievement {.importc: "rc_client_get_achievement_info".}
{.pop.}
proc rcMemoryInit*(regions: ptr RcRegions, memoryMap: pointer, getter: RcMemoryGetter, console: uint32): cint {.cdecl, importc: "rc_libretro_memory_init", header: "rc_libretro.h".}
proc rcMemoryDestroy*(regions: ptr RcRegions) {.cdecl, importc: "rc_libretro_memory_destroy", header: "rc_libretro.h".}
proc rcMemoryRead*(regions: ptr RcRegions, address: uint32, buffer: ptr uint8, count: uint32): uint32 {.cdecl, importc: "rc_libretro_memory_read", header: "rc_libretro.h".}
