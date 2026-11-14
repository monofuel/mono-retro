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

The `mono-retro/` folders are prepared on the DS Plus games card. Browsing,
RomM synchronization and card-backed game-launch configuration are separate
work. Existing test wrappers still use their isolated OS-card save directories.
Keep existing stock folders and filenames; no ROM reorganization is required.

Use `mono-retro/saves/<core>/<rom-sha1>/` for a game's `--save-dir` when
connecting the launcher. The current player stores `<ROM-stem>.srm`, `system/`,
`states/` and `captures/` beneath that directory. Separate core namespaces
avoid assuming that save formats are interchangeable. State imports also
check the ROM and core build; storing a state on the games card does not make
it compatible with every OS or core version.

The player additionally exports screenstates to `~/Pictures/Screenshots/`.
Those exports must be redirected to the card before enabling everyday play;
`--capture-dir` changes session storage, not that additional export location.
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

This entry is local OS configuration; it must also be retained when preparing
another OS card. It is not automatically added by the generic image builder.
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
