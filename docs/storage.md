# Games-card storage

Keep the OS and emulator cores on the system card. Keep games, saves and
portable frontend data on the second card so replacing an OS card does not
replace game progress. Desktop development can use an ordinary directory
with the same layout.

## Layout

```text
/media/games/
├── Roms/                        # Existing stock-compatible game folders.
│   └── NDS/
├── save_nnddss/                 # Stock saves and states; preserve separately.
└── mono-retro/
    ├── README.md
    ├── saves/                  # Per-core, per-game player save directories.
    ├── artwork/                # Cached cover art.
    ├── library/                # Library metadata and synchronization records.
    ├── settings/               # Portable preferences, without credentials.
    └── screenshots/            # Exported screenshots and screenstates.
```

The [library launcher](library.md) uses these folders for browsing, RomM
synchronization and card-backed play. Diagnostic test wrappers remain separate
and can deliberately use isolated OS-card save directories. Existing stock
folders can stay in place; the library does not require ROM reorganization.

Use `mono-retro/saves/<core>/<rom-sha1>/` for a game's `--save-dir` when
connecting the launcher. The current player stores `<ROM-stem>.srm`, `system/`,
`states/` and `captures/` beneath that directory. Separate core namespaces
avoid assuming that save formats are interchangeable. State imports also
check the ROM and core build; storing a state on the games card does not make
it compatible with every OS or core version.

Direct player launches default to exporting screenstates in
`~/Pictures/Screenshots/`. The library passes `--screenstate-dir` to put these
on the card too. `--capture-dir` changes session storage, not that additional
export location.
Credentials remain in protected OS storage, not on the exFAT card.

## Mounting on Gentoo

The DS Plus games card is exFAT with filesystem UUID `6635-3264`. Its OS card
has this optional `/etc/fstab` entry:

```fstab
UUID=6635-3264 /media/games exfat rw,nofail,noatime,nosuid,nodev,noexec,uid=1000,gid=1000,fmask=0133,dmask=0022,errors=remount-ro 0 0
```

For another card or OS image, inspect its filesystem UUID and the user's
numeric UID/GID before writing an entry. Device names such as `mmcblk2p1`
can change. Preserve existing root and boot entries. The root filesystem's
empty `/media/games` directory is owned by root with mode `0555`; mounting
the card presents its contents as writable by UID/GID 1000. exFAT ownership
and permissions come from mount options, not stored POSIX metadata.

`nofail` lets boot proceed when the card is absent. The launcher must verify
that the expected filesystem is mounted and writable before starting a game
or creating save directories. Directory existence alone is insufficient,
especially when the launcher runs as root. Never silently use the underlying
OS-card directory as a fallback.

Check or mount without restarting the launcher:

```sh
findmnt --verify
mount /media/games
findmnt -M /media/games -o SOURCE,TARGET,FSTYPE,OPTIONS
```

Monorig's `tools/handheld_library.nim HOST CARD_UUID [EARTHBOUND_SHA1]`
emits the mount entry and launcher configuration for an existing handheld.
Retain or regenerate this configuration when preparing another OS card; the
generic image builder does not guess which removable volume contains games.
OpenRC's `localmount` service mounts it before the existing launcher service.
The data volume is `noexec`; installed applications and cores stay on the OS
card. No automatic filesystem repair is enabled by this entry.

## Save preservation

The important Lost in Blue progress is the stock NNDDSS save on the games
card. The Gentoo performance-test save is an expendable copy of an older
backup. Keep stock `save_nnddss/` untouched while importing a copy for mono-retro.
NNDDSS `.dsv` files include container metadata; renaming one to `.srm` does
not convert it. Import/export and server synchronization require explicit
format handling. In-game saves and emulator states are separate artifacts.

Exit the game and shut down before removing the card. Lid closure or sleep
does not make removal safe. This mount setup does not implement hot swapping.
