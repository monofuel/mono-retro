# Menu styling and themes

Brainstorming for the mono-retro menu. These are ideas to explore; priorities,
visual designs and the theme interface remain open.

The menu should feel good on an RG SP, an RG DS Plus and an X11 desktop.
Different themes could make those experiences look and behave quite differently.

## What a theme could control

A theme should be able to choose the whole presentation and what gets prominence:

- Home screen, page layouts, navigation and information density.
- Cover grids, carousels, text lists, large buttons or a dashboard.
- Fonts, colours, icons, borders, backgrounds and artwork treatments.
- Selection indicators, transitions, loading states and optional sounds.
- Which information is visible immediately and which lives on a details page.
- How multiple displays are used, including different content on each screen.
- Touch targets, mouse interactions and controller hints for its layout.

For example, a game-focused theme might open straight into the library, while a
developer theme might open into Hardware Test, System Info and build details.
The original simple button menu is a useful starting point for that developer
theme. A theme could also present both games and tools as equally prominent
choices.

Launching games, reading battery information, RomM operations and managing saves
should remain shared application capabilities. Themes can present those actions
in their own ways. Storage checks, credential handling and explicit save-conflict
choices still belong to the application, so visual changes preserve their meaning.

## Possible themes

Names are working labels.

| Theme | Main idea | Possible home screen |
| --- | --- | --- |
| Showcase | Let the selected game fill the screen with personality. | Large artwork, title and a small row of neighbouring games. |
| Pocket | Playful handheld presentation with crisp shapes and chunky icons. | Compact game cards, system tabs and a bright selection marker. |
| Library | Browse a collection comfortably, including similarly named versions. | Cover grid or detailed list with useful filters and sorting. |
| Workbench | Put testing and understanding the device first. | Large buttons for Hardware Test, System Info, games and sync tools. |
| Minimal | Quick access with little decoration. | Text list, selected-game details and a small status bar. |
| Desktop | Take advantage of a large resizable window and mouse input. | Library beside a persistent details panel and tools sidebar. |

A single theme might adapt across devices, or offer specific single-screen and
dual-screen compositions. We do not need to decide yet whether Desktop is a
separate theme or a layout option within others.

## Make browsing feel satisfying

### Artwork and selected-game presentation

- Give the selected cover more space and a clear visual relationship to its title.
- Explore game logos, screenshots and wide artwork as well as box covers.
- Sample an accent colour from the artwork for selection, headings or borders.
- Try a restrained background wash, cropped screenshot or illustrated backdrop.
- Offer different cover sizes and a text-list view for larger collections.
- Make missing artwork look deliberate: title, system icon and a useful placeholder.
- Keep covers proportional and give pixel artwork a crisp presentation.
- Make long titles and translated-game names readable without constant scrolling.
- Show region, revision or translation details where they help distinguish games.
- Provide an obvious state for a downloaded game whose emulator is not selected.

### System identity

- Give GB, GBC, GBA, NES, SNES and DS distinct icons and accent colours.
- Explore a system landing page with its games, favourites and recently played titles.
- Let system transitions feel different from moving between individual covers.
- Try console silhouettes, cartridge shapes or simple original pixel icons.
- Allow themes to use their own system treatments while sharing the same library.

### Movement and feedback

- Slightly enlarge or lift the focused card.
- Use a moving underline, frame, glow or cursor appropriate to the theme.
- Scroll rows and pages smoothly with predictable stopping points.
- Fade artwork when changing selection; keep text and focus responsive.
- Preserve the selected game when returning from gameplay, details or settings.
- Show short, clear feedback when adding a favourite or finishing a download.
- Explore optional quiet navigation sounds and distinct confirm/back sounds.
- Offer reduced motion and independent control over menu sounds.
- Make held-button repeat feel consistent across different layouts.

Input should take effect immediately. Animations can follow the current
selection and change direction when the player moves again; the player should
never have to wait for a decorative transition to finish.

## Use each screen well

### RG DS Plus

- Game-focused: top screen as a game poster; bottom screen as the touch library.
- Details-focused: top screen for description and screenshots; bottom for selection.
- Workbench: top screen for device status; bottom for large test/tool buttons.
- Explore top-screen artwork changes that track bottom-screen selection immediately.
- Make touch targets comfortable for fingers as well as the stylus.
- Keep important actions reachable with physical buttons too.
- Try a coordinated transition across both screens when opening a game or tool.
- Consider whether a theme should allow swapping its top/bottom roles.

### RG SP

- Explore a cover grid, a horizontal strip and a focused one-game-at-a-time view.
- Give the selected game's title and primary action enough room on one screen.
- Keep controller hints readable and sensitive to the current page.
- Use a separate details page when descriptions would crowd the library.
- Let a developer theme resemble the original large-button launcher.

### X11 desktop

- Resize layouts naturally, including narrow and large windows.
- Explore a persistent details panel and keyboard-accessible search.
- Give hover feedback without requiring a mouse for navigation.
- Offer previews of both handheld layouts for theme development.
- Consider theme previews at actual handheld sizes before applying a selection.

## Make the device feel personal

- Prominent recently played games and favourites.
- A quick launch action for the last game.
- Custom collections, shelves or a small number of pinned games.
- Optional play-time information and last-played dates.
- User-selected backgrounds, accents and cover size.
- Theme-specific home-screen arrangements or favourite tools.
- A welcoming empty library with direct access to RomM and local scanning.

An eventual resume feature should make clear whether it boots the game with its
cartridge save or restores a specific emulator state. A save file's presence
alone does not prove that a resumable session exists.

## Status that earns its space

- Battery percentage, charging and the existing plugged-in-but-discharging case.
- A compact indication of pending or successfully completed save synchronization.
- Per-game last successful save-upload information, based on confirmed operations.
- Clear offline availability and download progress.
- An explicit choice when local and server saves conflict.
- A readable pairing link with a possible QR-code presentation.
- Optional clock and network indicators.
- More detailed storage, network, temperature and build information in Workbench.

Game-focused themes can keep routine status small. Developer themes can give it
much more room. A failed user action should explain what happened where that
action was requested, with enough information to recover.

## Developer and testing ideas

- Original-style buttons for Hardware Test, System Info, reboot and shutdown.
- Installed frontend/core versions and selected display backend.
- Battery, power and network details visible together.
- Quick access to silent display patterns and the hardware tester.
- Optional frame-time graph, redraw count and UI performance overlay.
- Visible controller focus and touch-target outlines for layout debugging.
- A theme gallery using synthetic games, long titles and missing artwork.
- Preview pages for downloads, pairing, conflicts, empty libraries and missing cards.
- A simple theme useful for diagnosing problems in more elaborate themes.

Testing indicators and telemetry could be available across themes as an optional
overlay, as well as having a dedicated Workbench presentation.

## Theme selection and implementation questions

- A theme picker with screenshots or a live preview and an explicit Apply action.
- Remember the chosen theme per device; the same games card may travel between devices.
- Keep favourites, library identity and save paths consistent when changing themes.
- Consider per-theme options for density, artwork, motion, sound and home page.
- Decide how much to share between themes: typography helpers, cards, toolbars,
  status indicators and common interaction patterns.
- Explore Nim theme modules for layouts and behaviour, with data-driven options
  for colours and assets. The exact interface is still a design question.
- Use the existing Windy, Pixie, Paddy and Slappy stack; reusable generic library
  improvements should have a concrete need and stay separate from app themes.
- Keep the cost of artwork decoding, redraws and animations visible during design.
- Explore richer GPU effects where practical, alongside themes that suit the SP's
  existing framebuffer path. Measure on the physical devices.

## Things to compare in mockups

Useful first comparisons could be Showcase, Pocket and Workbench, all showing
the same small library on both single-screen and dual-screen layouts.

Compare how quickly someone can find a game, launch Hardware Test, read the
battery state and understand a save-sync problem. Include missing artwork and
long names so the designs work beyond a carefully arranged screenshot.

Related: [library behaviour](library.md), [launcher](launcher.md),
[hardware tester](hardware-test.md) and [player performance](player-performance.md).
