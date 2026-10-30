import
  std/[monotimes, os, tables, times],
  ./[ra_config, ra_ffi, ra_http, ra_types]

const
  LoginTimeoutSeconds = 20
  LoginPollMs = 10

type
  PendingCall = object
    callback: RcServerCallback
    userdata: pointer
  RaRuntime* = ref object
    client: ptr RcClient
    transport: RaHttp
    memory: RaMemoryProvider
    regions: RcRegions
    requests: Table[uint64, PendingCall]
    nextRequest: uint64
    view: RaSnapshot
    notices: seq[RaNotice]
    cached: seq[RaAchievement]
    listDirty, closing, loginOnly, loginFinished: bool
    romPath, romData: string

var mappingRuntime {.threadvar.}: RaRuntime

proc refreshMemory*(runtime: RaRuntime)
proc close*(runtime: RaRuntime)

proc owner(client: ptr RcClient): RaRuntime =
  ## Recover the caller-owned runtime associated with the opaque SDK client.
  cast[RaRuntime](rcGetUserdata(client))

proc copyString(value: cstring): string =
  ## Copy borrowed SDK text before its callback or owning object expires.
  if value != nil: result = $value

proc readMemory(address: uint32, buffer: ptr uint8, count: uint32,
    client: ptr RcClient): uint32 {.cdecl.} =
  ## Read only the owner's mapped memory; never emulate bus reads or access HTTP state.
  let runtime = owner(client)
  if runtime == nil or runtime.closing: return 0
  rcMemoryRead(addr runtime.regions, address, buffer, count)

proc getMemory(id: uint32, info: ptr RcMemoryInfo) {.cdecl.} =
  ## Adapt libretro's userdata-free memory callback on the current owner thread.
  info.data = nil
  info.size = 0
  if mappingRuntime == nil or mappingRuntime.memory == nil: return
  try:
    let memory = mappingRuntime.memory(id)
    if memory.data != nil and memory.size > 0:
      info.data = cast[ptr uint8](memory.data)
      info.size = memory.size.csize_t
  except CatchableError:
    mappingRuntime.view.status = RaFailed
    mappingRuntime.view.message = "Achievement memory is unavailable."

proc refreshMemory*(runtime: RaRuntime) =
  ## Refresh borrowed RAM pointers after reset or successful state import.
  if runtime == nil or runtime.client == nil or runtime.closing: return
  rcMemoryDestroy(addr runtime.regions)
  mappingRuntime = runtime
  try:
    discard rcMemoryInit(addr runtime.regions, nil, getMemory, RcSnes)
  finally:
    mappingRuntime = nil

proc summarize(runtime: RaRuntime) =
  ## Refresh small counters only when game or achievement state changes.
  var summary: RcSummary
  rcSummary(runtime.client, addr summary)
  runtime.view.total = summary.total.int
  runtime.view.unlocked = summary.unlocked.int

proc onEvent(event: ptr RcEvent, client: ptr RcClient) {.cdecl.} =
  ## Publish copied notices and invalidate cached list metadata on SDK events.
  let runtime = owner(client)
  if runtime == nil or runtime.closing: return
  case event.`type`
  of RcAchievementTriggered:
    if event.achievement != nil:
      let achievement = event.achievement
      runtime.notices.add(RaNotice(title: copyString(achievement.title),
        description: copyString(achievement.description), points: achievement.points.int))
      runtime.listDirty = true
      runtime.summarize()
  of RcServerError:
    runtime.view.message = "The achievement service reported an error."
  of RcDisconnected:
    runtime.view.message = "Offline; achievement submissions will retry."
  of RcReconnected:
    runtime.view.message = ""
  else:
    discard

proc serverCall(request: ptr RcRequest, callback: RcServerCallback,
    userdata: pointer, client: ptr RcClient) {.cdecl.} =
  ## Copy temporary request fields and retain SDK callbacks solely on the owner.
  let runtime = owner(client)
  if runtime.closing:
    var response = RcResponse(httpStatus: RcClientError)
    callback(addr response, userdata)
    return
  inc runtime.nextRequest
  let id = runtime.nextRequest
  runtime.requests[id] = PendingCall(callback: callback, userdata: userdata)
  runtime.transport.submit(RaHttpRequest(id: id, url: copyString(request.url),
    body: copyString(request.postData), contentType: copyString(request.contentType),
    post: request.postData != nil))

proc complete(runtime: RaRuntime, response: RaHttpResponse) =
  ## Invoke each saved callback exactly once with owned response storage alive.
  if response.id notin runtime.requests: return
  let pending = runtime.requests[response.id]
  runtime.requests.del(response.id)
  var sdkResponse = RcResponse(body: response.body.cstring,
    bodyLength: response.body.len.csize_t,
    httpStatus: (if runtime.closing or response.error == RaHttpCancelled: RcClientError
      elif response.error == RaHttpTransportError: RcRetryableError
      else: response.status.cint))
  pending.callback(addr sdkResponse, pending.userdata)

proc pump(runtime: RaRuntime) =
  ## Deliver transport completions without running SDK code on the HTTP thread.
  for response in runtime.transport.takeResponses():
    runtime.complete(response)

proc loaded(code: cint, message: RcConstString, client: ptr RcClient,
    userdata: pointer) {.cdecl.} =
  ## Publish a game summary without exposing untrusted server error text.
  let runtime = owner(client)
  if runtime.closing: return
  if code != RcOk:
    runtime.view.status = RaUnavailable
    runtime.view.message = "Achievements are unavailable for this ROM."
    return
  let game = rcGetGame(client)
  if game == nil or game.id == 0:
    runtime.view.status = RaUnavailable
    runtime.view.message = "This ROM has no recognized achievement set."
    return
  runtime.view.status = RaReady
  runtime.view.message = ""
  runtime.view.gameTitle = copyString(game.title)
  runtime.listDirty = true
  runtime.summarize()

proc loggedIn(code: cint, message: RcConstString, client: ptr RcClient,
    userdata: pointer) {.cdecl.} =
  ## Finish authentication or start identifying the original SNES ROM bytes.
  let runtime = owner(client)
  if runtime.closing: return
  runtime.loginFinished = true
  if code != RcOk:
    runtime.view.status = RaFailed
    runtime.view.message = "RetroAchievements login failed. Check your account and connection."
    return
  let user = rcGetUser(client)
  if user != nil: runtime.view.username = copyString(user.username)
  if runtime.loginOnly:
    runtime.view.status = RaReady
    return
  discard rcLoadGame(client, RcSnes, runtime.romPath.cstring,
    (if runtime.romData.len > 0: cast[ptr uint8](unsafeAddr runtime.romData[0]) else: nil),
    runtime.romData.len.csize_t, cast[RcCallback](loaded), nil)

proc initialize(runtime: RaRuntime) =
  ## Create a Casual-only SDK instance with all memory work confined to its owner.
  runtime.client = rcCreate(readMemory, cast[RcServerCall](serverCall))
  if runtime.client == nil:
    raise newException(OutOfMemDefect, "Cannot create achievement client.")
  try:
    runtime.transport = newRaHttp()
    rcSetUserdata(runtime.client, cast[pointer](runtime))
    rcSetHardcore(runtime.client, 0)
    rcSetBackgroundReads(runtime.client, 0)
    rcSetEvents(runtime.client, cast[RcEventHandler](onEvent))
    runtime.refreshMemory()
  except:
    # Release partial ownership and preserve the original exception, including defects.
    discard runtime.transport.close()
    runtime.transport = nil
    rcMemoryDestroy(addr runtime.regions)
    rcDestroy(runtime.client)
    runtime.client = nil
    raise

proc newRaRuntime*(configPath: string, enabled, supported: bool,
    romPath, romData: string, memory: RaMemoryProvider): RaRuntime =
  ## Start optional Casual achievements without making auth failures fatal to gameplay.
  if not enabled: return nil
  result = RaRuntime(memory: memory, romPath: romPath, romData: romData)
  if not supported:
    result.view.status = RaUnavailable
    result.view.message = "Achievements are unavailable for this core."
    return
  var credentials: RaCredentials
  try:
    credentials = loadRaCredentials(resolveRaConfig(configPath))
  except CatchableError:
    result.view.status = RaFailed
    result.view.message = "Achievement configuration could not be read."
    return
  if credentials.username.len == 0 or credentials.token.len == 0:
    result.view.status = RaUnconfigured
    result.view.message = "Run mono-retro-ra login to configure achievements."
    return
  result.view.status = RaConnecting
  result.view.username = credentials.username
  when defined(raTesting):
    result.initialize()
  else:
    try:
      result.initialize()
    except CatchableError:
      result.view.status = RaFailed
      result.view.message = "Achievements could not be started."
      return
  discard rcLoginToken(result.client, credentials.username.cstring,
    credentials.token.cstring, cast[RcCallback](loggedIn), nil)

proc frame*(runtime: RaRuntime) =
  ## Process exactly one completed emulated frame, regardless of presentation.
  if runtime == nil or runtime.client == nil or runtime.closing: return
  runtime.pump()
  rcFrame(runtime.client)

proc idle*(runtime: RaRuntime) =
  ## Deliver authentication, retries and timers while emulation is paused.
  if runtime == nil or runtime.client == nil or runtime.closing: return
  runtime.pump()
  rcIdle(runtime.client)

proc resetProgress*(runtime: RaRuntime) =
  ## Reset runtime deltas after importing a legacy state without achievement progress.
  if runtime == nil or runtime.client == nil or runtime.closing: return
  discard rcResetProgress(runtime.client, nil, 0)
  runtime.notices.setLen(0)
  runtime.listDirty = true

proc rebuildList(runtime: RaRuntime) =
  ## Copy list metadata only after changes or when explicitly requested by the overlay.
  let list = rcList(runtime.client, RcCategoryCore, RcGroupingLockState)
  if list == nil: return
  defer: rcDestroyList(list)
  runtime.cached.setLen(0)
  for bucketIndex in 0..<list.count.int:
    let bucket = list.buckets[bucketIndex]
    for index in 0..<bucket.count.int:
      let achievement = bucket.achievements[index]
      runtime.cached.add(RaAchievement(id: achievement.id,
        title: copyString(achievement.title), description: copyString(achievement.description),
        points: achievement.points.int, unlocked: achievement.state == RcUnlocked))
  runtime.listDirty = false

proc snapshot*(runtime: RaRuntime, withList = false): RaSnapshot =
  ## Return small metadata normally, or an explicitly requested copied achievement list.
  if runtime == nil: return RaSnapshot(status: RaDisabled)
  result = runtime.view
  result.hasList = withList
  if withList and runtime.client != nil:
    if runtime.listDirty: runtime.rebuildList()
    result.achievements = newSeq[RaAchievement](runtime.cached.len)
    for index, achievement in runtime.cached:
      result.achievements[index] = achievement
      let current = rcAchievement(runtime.client, achievement.id)
      if current != nil:
        result.achievements[index].unlocked = current.state == RcUnlocked
        for character in current.measuredProgress:
          if character == '\0': break
          result.achievements[index].progress.add(character)

proc takeNotices*(runtime: RaRuntime): seq[RaNotice] =
  ## Transfer copied pending popup values to the caller.
  if runtime == nil: return
  result = move(runtime.notices)

proc close*(runtime: RaRuntime) =
  ## Settle transport callbacks and join its worker before releasing SDK and RAM pointers.
  if runtime == nil or runtime.closing: return
  runtime.closing = true
  if runtime.client == nil: return
  for response in runtime.transport.close(): runtime.complete(response)
  # Cancelled/in-flight callbacks can enqueue no new network work once closing is set.
  while runtime.requests.len > 0:
    var id: uint64
    for key in runtime.requests.keys:
      id = key
      break
    runtime.complete(RaHttpResponse(id: id, error: RaHttpCancelled))
  # The pinned SDK's unload clears game before emitting pending mastery events.
  # Flush them through the public reset API while game is valid, without evaluating RAM.
  discard rcResetProgress(runtime.client, nil, 0)
  rcUnload(runtime.client)
  rcDestroy(runtime.client)
  runtime.client = nil
  rcMemoryDestroy(addr runtime.regions)
  runtime.memory = nil
  runtime.romData.setLen(0)
  runtime.cached.setLen(0)

proc loginRa*(username, password: string): RaCredentials =
  ## Exchange a password for an API token; callers persist only the returned credentials.
  if username.len == 0 or password.len == 0:
    raise newException(ValueError, "A username and password are required.")
  let runtime = RaRuntime(loginOnly: true)
  runtime.view.status = RaConnecting
  runtime.initialize()
  defer: runtime.close()
  discard rcLoginPassword(runtime.client, username.cstring, password.cstring,
    cast[RcCallback](loggedIn), nil)
  let deadline = getMonoTime() + initDuration(seconds = LoginTimeoutSeconds)
  while not runtime.loginFinished and getMonoTime() < deadline:
    runtime.idle()
    if not runtime.loginFinished: sleep(LoginPollMs)
  if not runtime.loginFinished or runtime.view.status != RaReady:
    raise newException(IOError, "RetroAchievements login failed. Check your account and connection.")
  let user = rcGetUser(runtime.client)
  if user == nil or user.token == nil:
    raise newException(IOError, "RetroAchievements login did not return a token.")
  result = RaCredentials(username: copyString(user.username), token: copyString(user.token))
