# Game library

The library menu browses local games, downloads selected RomM collections and
syncs in-game saves. It uses the same player, hardware profiles and Linux
display backends as the diagnostic launcher. The UI uses Windy, Pixie and
Paddy; the shared library CLI uses Curly for HTTPS and streaming downloads.

## Start

Build with `make launcher-desktop player-desktop`. On NixOS, use
`nix-shell shell-player.nix` for the native libraries. Start with:

```sh
build/mono-retro --library:/path/to/games --config:/path/to/library.json
```

Both executables and `mono-retro-library` must be installed together. Without
`--library`, the launcher retains its diagnostic menu and explicit test wrappers.

The library directory contains `Roms/` and the `mono-retro/` data folders
described in [storage](storage.md). Desktop configuration can omit the card UUID:

```json
{
  "expectedUuid": "",
  "rommUrl": "https://romm.example",
  "playerPath": "/absolute/path/to/mono-retro-player",
  "cores": [
    {
      "key": "mgba",
      "path": "/absolute/path/to/mgba_libretro.so",
      "platforms": ["gba", "gb", "gbc"],
      "arguments": []
    },
    {
      "key": "melondsds",
      "path": "/absolute/path/to/melondsds_libretro.so",
      "platforms": ["nds"],
      "arguments": ["--ds-layout:separate"]
    }
  ]
}
```

Handheld configuration requires the actual mounted card UUID. No library
operation silently creates a substitute game directory when that card is absent.
For Decompbound, add an exact `romHash` association rather than assigning it
to all SNES games. `arguments` are passed directly to the player, without a shell.
Core libraries remain externally installed artifacts.

## Browse and play

- D-pad/arrows/stick: move through covers; L/R or Q/E: change system/filter.
- A/Enter: play. X: details. Y: favourite. B/Escape: back.
- Start/Tab: menu, including Hardware Test, System Info and power controls.
- Touch/click a cover to select it; use Play to launch.
- DS Plus: covers and touch controls below, selected-game details above.
  Single-screen devices use the same grid with a separate details page.

The scanner recognizes loose `.nds`, `.gba`, `.gb`, `.gbc`, `.smc` and `.sfc`
files. It does not patch, trim, rename or extract existing ROMs. Content hashes
separate same-named revisions and retain favourites/history when files move.
Games without a configured installed core cannot launch.

Each game uses `mono-retro/saves/<core>/<ROM-SHA1>/` for cartridge data,
system files, state slots and recorded sessions. Exported screenstates go to
`mono-retro/screenshots/` through the player's `--screenstate-dir` option.
State compatibility still depends on the ROM, core build and options.

## Connect to RomM

Configure the server origin, then choose **Menu → Connect to RomM**. The menu
shows a URL and short approval code. Open the URL in a browser, sign in and
approve the device. The handheld polls at the server's requested interval and
stores the returned device-bound token in `private/romm-credentials.json`
beside its OS configuration. No account password is entered on the handheld.

The integration targets RomM 5.4.0's device authorization and save-sync APIs.
It requests ROM/platform/collection read permissions plus device and save
permissions. Tokens are owner-only files; they do not belong on exFAT or in
the portable library index. HTTPS verification stays enabled. Disconnect
forgets the local token; revoke it in RomM to invalidate it server-side too.

Choose **RomM collections**, then A/tap to toggle automatic downloads. Create
ordinary collections in RomM's web UI if none exist. The launcher refreshes
on startup, after gameplay and through **Sync now**. Existing local files are
matched by hash. Downloads are streamed and checked before publication;
removing a collection selection does not delete games or saves.

Installed games remain playable offline. Before launch and after exit, raw
cartridge saves sync with the server's `autosave` slot. Named/archival slots
and emulator states are not substituted for that active save. Failed network
sync leaves local progress intact; Play again continues with the local save.
The next successful sync retries pending local changes.

If local and server saves conflict, choose which to continue with. Both
versions are preserved before applying the choice. A remote deletion also
requires explicit review. `.dsv` containers need a separate one-off conversion;
the sync client accepts raw `.sav`/`.srm` progress, not cross-emulator states.
Synchronization does not replace independent archival backups.

## CLI and deployment

The UI runs these same operations in an owned worker process, keeping network
and scan work off the display loop. Downloads stop before gameplay starts.

```sh
mono-retro-library scan --library:/media/games --config:/etc/mono-retro/library.json
mono-retro-library status --library:/media/games --config:/etc/mono-retro/library.json
mono-retro-library pair --library:/media/games --config:/etc/mono-retro/library.json
mono-retro-library sync --library:/media/games --config:/etc/mono-retro/library.json
```

Additional commands are `collections`, `select --id:N`, `favourite --game:SHA1`,
`played --game:SHA1`, `sync-saves --game:SHA1`, `resolve --game:SHA1
--choice:local|server`, and `disconnect`. Status output contains no credentials.
Writers use a process lock and atomically publish the portable index.

Monorig's `tools/handheld_library.nim HOST CARD_UUID [EARTHBOUND_SHA1]`
emits the secret-free mount/configuration script for either handheld. It
preserves stock ROM/save folders, enables the library through OpenRC's service
arguments, and records libretro-only mGBA USE flags. Install the binaries and
cores first; the script does not rebuild an image or modify networking.

Tests cover storage and discovery, every page at handheld sizes, mocked RomM
pairing/download/save failures, and repeated player handoffs under isolated X11.
Automated playback remains muted; manual gameplay retains normal audio.
