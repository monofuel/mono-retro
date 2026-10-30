import
  std/[os, parseopt, strutils, terminal],
  retro/[ra_client, ra_config, ra_types]

const Help = """Usage: mono-retro-ra login|status|logout [--ra-config:PATH]
Login prompts privately and remembers the returned token, never your password.
Status reports local configuration without connecting to RetroAchievements.
Logout forgets the local token for subsequent player launches.
"""

proc main() =
  ## Configure the same private achievement account used by mono-retro-player.
  var
    action, overridePath: string
    parser = initOptParser(commandLineParams())
  for kind, key, value in parser.getopt():
    case kind
    of cmdArgument:
      if action.len > 0: raise newException(ValueError, Help)
      action = key
    of cmdLongOption:
      case key
      of "ra-config":
        if value.len == 0: raise newException(ValueError, "Missing configuration path")
        overridePath = value
      of "help": stdout.write(Help); return
      else: raise newException(ValueError, Help)
    else: raise newException(ValueError, Help)
  if action notin ["login", "status", "logout"]:
    stdout.write(Help)
    quit(1)
  let path = resolveRaConfig(overridePath)
  case action
  of "login":
    stdout.write("Username: ")
    stdout.flushFile()
    let username = stdin.readLine().strip()
    if username.len == 0: raise newException(ValueError, "Username is required")
    var password: string
    if not readPasswordFromStdin("Password: ", password):
      raise newException(IOError, "Cannot read password privately from this terminal")
    let credentials = loginRa(username, password)
    password.setLen(0)
    saveRaCredentials(path, credentials)
    echo "Configured RetroAchievements for ", credentials.username
    echo "Config: ", path
  of "status":
    let credentials = loadRaCredentials(path)
    if credentials.username.len == 0: echo "RetroAchievements is not configured."
    else: echo "Configured account: ", credentials.username
    echo "Config: ", path
  of "logout":
    forgetRaCredentials(path)
    echo "Forgot the local RetroAchievements token. Restart the player to apply."
  else: discard

when isMainModule:
  main()
