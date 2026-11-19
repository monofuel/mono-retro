# Wi-Fi settings

Open **Start → Settings → Wi-Fi**. On a desktop, Tab opens the menu.
The list shows nearby networks, signal strength and configured profiles. On the
DS Plus, connection details appear above and the list or keyboard appears below.
Current status refreshes while the Wi-Fi page is open.

Select a network with the D-pad, stick, touch or mouse. Configured profiles and
open networks have a separate Connect confirmation. A new password-protected
network opens the keyboard; its **Connect** key submits the password. Selecting
or scanning a network does not join it.

The keyboard starts masked. **Show** explicitly reveals the text. It includes
letters, numbers, symbols, space, Shift, cursor arrows and backspace. A presses
the focused key, X deletes, Y shifts, L/R move the cursor and Start submits.
B cancels. Desktop typing, Backspace, arrow keys, Enter and Escape also work.
Passwords are entered on the device, rather than in a chat or shell argument.

A failed or cancelled join removes its temporary profile and restores the
previous configuration and selection. The page reports restoration problems
and displays the manager's actual connection state; restoring a configuration
is not proof that radio association has already completed. If a scan or status
request is still running, wait for it or use Back before starting a join.

## Network manager and saved profiles

The helper uses the existing `wpa_supplicant` control socket and DHCP setup.
Connection changes require wpa_supplicant 2.0 or newer; unknown or older
versions can still be queried. There is no replacement network service.
A new profile is saved only after authorization and an observed usable address.
If the address is unchanged from the previous network, the UI says network
readiness is unconfirmed. Wi-Fi association and an IP address do not prove
Internet access.

Existing profiles are reused without reading their passwords. New WPA
passphrases become derived hex keys. Credentials travel to the helper on stdin
and then a private Unix socket. They are excluded from process arguments,
results and progress messages. Passwords and keys are never written to the
games card.

The running daemon's protected configuration path is discovered from its `-c`
argument. Saving preserves its existing bytes in a private same-directory copy,
appends the new profile, syncs and atomically replaces the file. Wrong owner,
permissions, symlinks, hard links or concurrent replacement cause saving to fail
explicitly. A save failure can leave a working connection for the current
session, and the UI reports that it was not saved. Reapplying a generated
monorig Wi-Fi configuration may replace locally added profiles.

Open networks and conventional WPA/WPA2 Personal PSK networks are supported.
Enterprise, WEP, Enhanced Open and WPA3-only networks are labelled unsupported.
PSK-SHA256-only access points are not supported yet. Very large scan lists may
be limited by the manager's reply size. Earlier scan results are labelled when
a new scan has not been confirmed complete.

## Installation and checks

`make launcher-desktop` builds the menu and `build/mono-retro-wifi`;
`make launcher-handhelds` builds their ARM64 variants. Install the helper beside
the active launcher. On the DS Plus's ROCKNIX kernel profile that directory is
`/usr/local/libexec/mono-retro-rocknix/`. The launcher needs access to the manager's
control socket and sufficient permission to save its protected configuration.
Missing support is shown as unavailable.

Safe CLI inspection uses `mono-retro-wifi status` or
`mono-retro-wifi scan --cached`. The latter reads existing scan results.
`scan` requests a fresh scan but does not select or save a network.
The program's `--help` describes its explicit connect command; automated
qualification should use the fake manager in `tests/test_wifi.nim`.

The keyboard is also available independently: [reusing touchkeyboard](touchkeyboard.md).
