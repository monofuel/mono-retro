import std/[json, tables, uri]
import retro/ra_http

proc requestFields*(request: RaHttpRequest): Table[string, string] =
  ## Decode only synthetic SDK requests for assertions in isolated tests.
  for key, value in decodeQuery(request.body): result[key] = value

proc fixtureTransport*(request: RaHttpRequest): RaHttpResponse {.nimcall.} =
  ## Serve invented account and achievement data without any network capability.
  let fields = request.requestFields()
  result.status = 200
  result.body = "{\"Success\":true}"
  case fields.getOrDefault("r")
  of "login2":
    result.body = "{\"Success\":true,\"User\":\"SyntheticUser\",\"Token\":\"synthetic-token\",\"Score\":0,\"SoftcoreScore\":0,\"Messages\":0}"
  of "achievementsets":
    var achievements = newJArray()
    for index, condition in ["0xH000000=2", "0xH01ffff=9", "0xH020000=7", "0xH021fff=8"]:
      achievements.add(%*{"ID": index + 1, "Title": "Synthetic " & $(index + 1),
        "Description": "An invented RAM condition.", "Flags": 3, "Points": 5,
        "MemAddr": condition, "Author": "Fixture", "BadgeName": "00001",
        "Created": 1, "Modified": 1})
    result.body = $(%*{"Success": true, "GameId": 1, "Title": "Synthetic RAM game",
      "ConsoleId": 3, "ImageIconUrl": "https://example.invalid/icon.png",
      "Sets": [{"AchievementSetId": 1, "GameId": 1, "Title": "Synthetic RAM game",
        "Type": "core", "ImageIconUrl": "https://example.invalid/icon.png",
        "Achievements": achievements, "Leaderboards": []}]})
  of "startsession":
    doAssert fields.getOrDefault("h") == "0"
    result.body = "{\"Success\":true,\"Unlocks\":[],\"HardcoreUnlocks\":[]}"
  of "awardachievement":
    doAssert fields.getOrDefault("h") == "0"
    result.body = "{\"Success\":true,\"Score\":5,\"SoftcoreScore\":5,\"AchievementID\":" &
      fields["a"] & ",\"AchievementsRemaining\":0}"
  of "ping": discard
  else: raise newException(ValueError, "Unexpected synthetic SDK action")
