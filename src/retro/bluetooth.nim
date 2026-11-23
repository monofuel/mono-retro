import
  std/[json, jsonutils, strutils]

type
  BtPromptKind* = enum
    NoPrompt, PinPrompt, PasskeyPrompt, ConfirmPrompt, DisplayPrompt
  BtDevice* = object
    address*, name*, icon*: string
    paired*, trusted*, connected*, audioReady*, gamepadReady*: bool
    batteryPercent*: int
  BtPrompt* = object
    kind*: BtPromptKind
    address*, text*, code*: string
    passkey*: uint32
  BtState* = object
    request*: uint64
    available*, powered*, discovering*, busy*: bool
    message*, error*: string
    devices*: seq[BtDevice]
    prompt*: BtPrompt
  BtCommand* = object
    request*: uint64
    action*, address*, value*: string
    enabled*: bool

proc validateAddress*(address: string): bool =
  ## Accept only a six-octet Bluetooth address with colon separators.
  if address.len != 17: return false
  for index, character in address:
    if index mod 3 == 2:
      if character != ':': return false
    elif character notin HexDigits: return false
  true

proc stateFromJson*(text: string): BtState =
  ## Decode the complete worker snapshot using symbolic prompt enum names.
  jsonTo(parseJson(text), BtState)

proc commandJson*(command: BtCommand): string =
  ## Encode one worker command; callers must send secrets only through stdin.
  $command.toJson()

proc stateJson*(state: BtState): string =
  ## Encode the complete worker state, including any current private prompt.
  $state.toJson(ToJsonOptions(enumMode: joptEnumString))

proc commandFromJson*(text: string): BtCommand =
  ## Decode a command without including its contents in validation errors.
  try:
    result = jsonTo(parseJson(text), BtCommand, Joptions(allowMissingKeys: true))
  except CatchableError:
    raise newException(ValueError, "Invalid Bluetooth command")
