# Audio during testing

- Agent-initiated automated playback must use `--mute` or a verified null audio
  backend. Audible automated runs require explicit, immediate permission for that run.
- Human manual tests use normal audio unless monofuel requests silence. An explicit
  request for a particular manual playback session authorizes its normal audio;
  general implementation, profiling or deployment requests do not.
- Human-run launch commands should not force mute. Agents must explicitly select
  silent playback for their own tests and preserve running manual sessions.

# Library boundaries

- Device-specific mappings, profiles and hardware quirks belong in mono-retro.
- Treat externally maintained libraries such as Treeform's Paddy like SDL:
  consume their public interfaces rather than putting this app's concerns in them.
- Prefer app-side adaptation when existing interfaces expose enough information.
  Propose an interface change only for a concrete capability the app cannot access.
- Keep upstream PRs focused on one generic library concern. Separate unrelated
  fixes and refactors; do not bundle them with support for a personal device.
- Use Nimby for Nim dependencies.
