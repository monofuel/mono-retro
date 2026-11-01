# Manual verification

Agent tests must remain silent. These instructions are for monofuel; they do not
authorize agents to launch audible playback.

| Check | Run | Pass if |
|---|---|---|
| Shared speaker volume | On RG DS Plus ROCKNIX, adjust volume in the launcher, open a game, adjust there, return to the launcher, and relaunch. | The level follows across applications, both speakers change together, 0% is silent, hold-repeat works, and the bottom-screen indicator expires after two seconds. |
| Save slots | In Decompbound, open Menu → Save State, save into several slots, then try replacing one and cancel once. | Each slot shows the correct combined-screen preview and save time; cancelling preserves its old contents; completion is reported after writing. |
| State restoration | Advance beyond a saved point, open Menu → Load State, cancel once, then confirm. Repeat with Recent Captures and a known F12. | Cancel leaves the session in place. Confirm restores the selected state with correct graphics/input/audio, including EarthBound DS and extended viewport. |
| Other cores | Repeat save/load with a compatible non-Decompbound core and a disposable save directory. | The same menu works and unrelated games do not appear in Recent Captures. |
| Controls and achievements | Navigate with D-pad/stick, A/B, hardware Back, touch, and desktop mouse/keyboard. Open Achievements and return. | Input follows visible targets; the game stays paused throughout navigation; no menu button press reaches gameplay after resuming. |
| Compatibility and performance | Leave the menu closed, adjust volume during play, and use F12/exit captures as usual. | Normal gameplay retains smooth presentation, the toast stays on the lower panel, and existing captures remain resumable. |
