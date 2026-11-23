import
  std/[osproc, strutils, uri]

proc isPairingLink*(url, origin: string): bool =
  ## Accept only a complete web link on the configured RomM origin.
  if url.len == 0 or origin.len == 0 or not url.startsWith(origin.strip(chars = {'/'}) & "/"):
    return false
  for character in url:
    if ord(character) <= 32 or ord(character) == 127: return false
  try:
    let parsed = parseUri(url)
    result = parsed.scheme in ["https", "http"] and parsed.hostname.len > 0 and
      parsed.username.len == 0 and parsed.password.len == 0
  except ValueError:
    discard

proc openPairingLink*(url, origin: string): Process =
  ## Launch the desktop opener using one URL argument; the caller reaps it without killing browsers.
  if not isPairingLink(url, origin): raise newException(ValueError, "Invalid RomM approval link")
  startProcess("xdg-open", args = [url], options = {poUsePath, poParentStreams})
