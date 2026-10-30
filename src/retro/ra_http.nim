import
  std/[atomics, httpclient, net, strutils, uri],
  ./ra_build

const
  RequestTimeoutMs = 5000
  MaximumPendingRequests = 128
  UserAgent = "mono-retro-player/0.1 rcheevos/" & RaVersion

type
  RaHttpError* = enum
    RaHttpNoError, RaHttpTransportError, RaHttpCancelled
  RaHttpRequest* = object
    id*: uint64
    url*, body*, contentType*: string
    post*: bool
  RaHttpResponse* = object
    id*: uint64
    body*: string
    status*: int
    error*: RaHttpError
  HttpJobKind = enum
    HttpRequest, HttpStop
  HttpJob = object
    kind: HttpJobKind
    request: RaHttpRequest
  HttpMailbox = object
    jobs: Channel[HttpJob]
    replies: Channel[RaHttpResponse]
    stopping: Atomic[bool]
  RaHttp* = ref object
    mailbox: ptr HttpMailbox
    worker: Thread[ptr HttpMailbox]
    pending: int
    immediate: seq[RaHttpResponse]

when defined(raTesting):
  type RaHttpTestHandler* = proc(request: RaHttpRequest): RaHttpResponse
  var testHandler {.threadvar.}: RaHttpTestHandler

  proc setRaHttpTestHandler*(handler: RaHttpTestHandler) =
    ## Replace transport only in synthetic builds, which never permit real HTTP.
    testHandler = handler

proc requestHttp(request: RaHttpRequest): RaHttpResponse =
  ## Perform verified HTTPS without invoking client callbacks or reading core data.
  result.id = request.id
  result.error = RaHttpTransportError
  when defined(ssl) and not defined(raTesting):
    if not request.url.startsWith("https://"):
      return
    try:
      # Nim verifies certificate DNS names but does not check IP subject alternatives.
      if isIpAddress(parseUri(request.url).hostname): return
      let client = newHttpClient(userAgent = UserAgent, maxRedirects = 0,
        timeout = RequestTimeoutMs,
        sslContext = newContext(verifyMode = CVerifyPeerUseEnvVars))
      defer: client.close()
      if request.contentType.len > 0:
        client.headers["Content-Type"] = request.contentType
      let response = client.request(request.url,
        httpMethod = (if request.post: HttpPost else: HttpGet), body = request.body)
      result.status = response.code.int
      result.body = response.body
      result.error = RaHttpNoError
    except CatchableError:
      # Transport errors terminate at this boundary; exception text can contain credentials.
      result.error = RaHttpTransportError

proc serve(mailbox: ptr HttpMailbox) {.thread.} =
  ## Transfer owned HTTP values; all SDK interaction remains on the caller thread.
  while true:
    let job = mailbox.jobs.recv()
    if job.kind == HttpStop: break
    let response = if mailbox.stopping.load():
        RaHttpResponse(id: job.request.id, error: RaHttpCancelled)
      else:
        requestHttp(job.request)
    mailbox.replies.send(response)

proc newRaHttp*(): RaHttp =
  ## Create a dedicated network worker, or an isolated synthetic transport.
  when defined(raTesting):
    if testHandler == nil:
      raise newException(ValueError, "RA test transport has no handler; real HTTP is disabled.")
  result = RaHttp()
  when not defined(raTesting):
    result.mailbox = cast[ptr HttpMailbox](allocShared0(sizeof(HttpMailbox)))
    result.mailbox.jobs.open()
    result.mailbox.replies.open()
    try:
      createThread(result.worker, serve, result.mailbox)
    except CatchableError:
      result.mailbox.jobs.close()
      result.mailbox.replies.close()
      deallocShared(result.mailbox)
      result.mailbox = nil
      raise

proc submit*(transport: RaHttp, request: RaHttpRequest) =
  ## Enqueue a copied request without retaining SDK-owned strings.
  when defined(raTesting):
    if testHandler == nil:
      raise newException(ValueError, "RA test transport has no handler; real HTTP is disabled.")
    var response = testHandler(request)
    response.id = request.id
    transport.immediate.add(move(response))
  else:
    if transport.pending >= MaximumPendingRequests:
      transport.immediate.add(RaHttpResponse(id: request.id, error: RaHttpTransportError))
    else:
      inc transport.pending
      transport.mailbox.jobs.send(HttpJob(kind: HttpRequest, request: request))

proc takeResponses*(transport: RaHttp): seq[RaHttpResponse] =
  ## Return completed owned responses to the client owner without blocking.
  if transport == nil: return
  result = move(transport.immediate)
  when not defined(raTesting):
    if transport.mailbox == nil: return
    while true:
      let response = transport.mailbox.replies.tryRecv()
      if not response.dataAvailable: break
      dec transport.pending
      result.add(response.msg)

proc close*(transport: RaHttp): seq[RaHttpResponse] =
  ## Cancel queued work, join the worker and return every outstanding completion.
  if transport == nil: return
  when not defined(raTesting):
    if transport.mailbox != nil:
      transport.mailbox.stopping.store(true)
      transport.mailbox.jobs.send(HttpJob(kind: HttpStop))
      joinThread(transport.worker)
      result = transport.takeResponses()
      transport.mailbox.jobs.close()
      transport.mailbox.replies.close()
      deallocShared(transport.mailbox)
      transport.mailbox = nil
  else:
    result = transport.takeResponses()
