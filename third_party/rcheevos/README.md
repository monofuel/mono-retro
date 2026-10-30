# rcheevos

Unmodified upstream C headers and source from RetroAchievements/rcheevos,
version 12.5.0, commit `1433173220a7eaede6a9ed7a18e94117be1821e0`.
Source: https://github.com/RetroAchievements/rcheevos/tree/1433173220a7eaede6a9ed7a18e94117be1821e0
License: MIT; see LICENSE.

Only upstream include/, src/ and LICENSE are vendored. No tests, captures,
achievement definitions, game assets or user data are included.

src/retro/ra_build.nim compiles the client, API/runtime, ROM hashing and
libretro memory helpers. Disc, archive and encrypted hashing are disabled;
Windows RAIntegration/external-client and editor functionality are not built.
The client supplies neither networking nor UI. The frontend owns both.
