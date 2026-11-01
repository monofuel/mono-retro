# Handheld volume and pause menu

RG DS Plus devices using the ROCKNIX profile share speaker volume between the
launcher and every game in mono-retro-player. Press Volume Up or Volume Down
for a 5% change. Holding repeats after 400 ms and then every 100 ms. Pressing
both together stops adjustment. A blue/teal volume bar appears for two seconds
on the bottom screen, without pausing the game.

The percentage comes from the ALSA amplifier controls, including changes made
outside the player. Both speaker channels move together. The selected level is
stored in `/var/lib/mono-retro/volume.json` and restored before game audio starts.
On first use the existing mixer level is retained. This release controls the
current speaker path; it does not add headphone detection or routing. Other
profiles without volume configuration keep their existing audio behavior.

Press the Anbernic Menu button, controller Home, or F1 to pause. The menu offers
Resume, Save State, Load State, Achievements and Exit to Launcher. The upper
screen retains the frozen game; controls appear below. Desktop/single-screen
play uses an overlay. Use D-pad/stick/keyboard arrows, A/Enter to select, and
B/Back/Escape to return. Touch and mouse use the same controls. Menu/F1 resumes.

## Save and load

Each ROM has ten numbered slots. Save State shows the existing screenshot and
time, or Empty. Saving into an occupied slot requires confirmation. A successful
save contains the game pixels and matching machine state, including both screens
for dual-screen games. Menu graphics and volume indicators are excluded.

Load State has Slots and Recent Captures views. Use Left/Right or tap the source
heading to switch. Recent Captures discovers matching resumable PNGs in the
capture directory and `~/Pictures/Screenshots/`, newest first. Image-only periodic
screenshots are excluded. Thumbnails load for the visible page. Select a state
and confirm Load to replace the current session; Cancel is selected initially.

Slots are private files under `<save-dir>/states/<ROM-SHA1>/slot-01.png` through
`slot-10.png`. They are independent of periodic capture and work with
`--captures:off`. The same embedded `ebSt` and `mrSt` formats remain usable through
state drop or `--load-state`. Existing ROM/core compatibility checks still apply.
An unavailable state or failed operation shows its reason in the menu.

F12/Share, periodic screenshots, input recording, exit captures and existing
startup state options keep their existing behavior. There is no automatic slot
load at startup. Cores without serialization expose unavailable save/load actions.
