## Owned values shared by the achievement runtime, worker and overlay.

type
  RaStatus* = enum
    RaDisabled, RaUnconfigured, RaConnecting, RaReady, RaUnavailable, RaFailed
  RaCredentials* = object
    username*, token*: string
  RaAchievement* = object
    id*: uint32
    title*, description*, progress*: string
    points*: int
    unlocked*: bool
  RaNotice* = object
    title*, description*: string
    points*: int
  RaSnapshot* = object
    status*: RaStatus
    username*, gameTitle*, message*: string
    unlocked*, total*: int
    hasList*: bool
    achievements*: seq[RaAchievement]
  RaMemoryInfo* = object
    data*: pointer
    size*: int
  RaMemoryProvider* = proc(id: uint32): RaMemoryInfo

proc ownedText(value: string): string =
  ## Copy text before handing an achievement value to another thread.
  result = newString(value.len)
  if value.len > 0: copyMem(addr result[0], unsafeAddr value[0], value.len)

proc ownedSnapshot*(value: RaSnapshot): RaSnapshot =
  ## Copy borrowed runtime metadata and optional list values for the UI thread.
  result = RaSnapshot(status: value.status, username: ownedText(value.username),
    gameTitle: ownedText(value.gameTitle), message: ownedText(value.message),
    unlocked: value.unlocked, total: value.total, hasList: value.hasList)
  result.achievements = newSeq[RaAchievement](value.achievements.len)
  for index, item in value.achievements:
    result.achievements[index] = RaAchievement(id: item.id,
      title: ownedText(item.title), description: ownedText(item.description),
      progress: ownedText(item.progress), points: item.points, unlocked: item.unlocked)
