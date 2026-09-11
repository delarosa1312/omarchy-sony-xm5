# mdrctl

Control Sony MDR headphones (WH-1000XM5 and relatives) from Linux, with the aim
of driving them from a small Omarchy bar widget rather than Sony's app.

## Why this shape

The upstream [SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient)
(MIT) separates the protocol into a library from the GUI built on it, and the
library exposes a plain C interface. So we build that library unmodified and call
it from Python with ctypes:

- no fork to keep in sync with upstream
- no C++ of our own to maintain
- no third-party plugin running unsandboxed inside the shell

Upstream is pinned to a commit in `scripts/build-libmdr.sh`.

## Setup

    ./scripts/build-libmdr.sh

Needs `cmake`, `ninja`, a C++20 compiler, and the BlueZ and D-Bus development
files. The GUI is not built.

## Use

    install -Dm644 systemd-user/mdrctld.service ~/.config/systemd/user/
    systemctl --user daemon-reload
    systemctl --user start mdrctld       # add `enable` to have it at login

    bin/mdrctl status                    # what the headphones are doing
    bin/mdrctl watch                     # follow changes live
    bin/mdrctl mode ambient              # off | cancelling | ambient
    bin/mdrctl ambient 15                # ambient, level 0-20
    bin/mdrctl cycle                     # next mode; what a bar click runs

**Stop the daemon before using Sony's app**, on the phone or anywhere else. The
device allows one control session at a time and the daemon holds it:

    systemctl --user stop mdrctld

The probing tools remain, for looking at a device this does not yet understand:

    ./tools/probe.py          # connect, print state, disconnect
    ./tools/uuid_scan.py MAC  # find the service UUID of another Sony device
    ./tools/dump.py           # raw bytes from every endpoint

## Shape

    mdrctld  ── holds the one control session, publishes state, takes commands
       |          $XDG_RUNTIME_DIR/mdrctl/{state.json,sock}
       +── mdrctl               a socket away: status, watch, mode, cycle
       +── shell-plugin/        the Omarchy bar widget and its popup
       +── bar/omarchy-headphones   a plain Waybar-JSON script, kept as a
                                    fallback for bars without a plugin system

The split exists because connecting is expensive and exclusive. A handshake
costs several seconds and locks everyone else out, so a bar widget cannot open
its own session: it would spend its life handshaking and would keep the phone
app out while doing it. The daemon pays that cost once. Everything above it
reads a file.

That also means the widget keeps working when the daemon is stopped -- BlueZ
publishes the battery over `org.bluez.Battery1` from the HFP indicator, with no
session needed, and the two agree. Only the noise mode needs the session.

## The bar widget

`shell-plugin/` is an Omarchy shell plugin: a chip on the bar and a popup with
the noise modes as a button group, an ambient-level slider, and the details.
It is a proper plugin rather than a `command` entry in `shell.json` because a
command widget can only print a line and run a command on click -- it cannot
open anything.

    ./scripts/sync-plugin.sh push      # repo -> ~/.config/omarchy/plugins/
    omarchy plugin enable delarosa.headphones

The shell hot-reloads plugin *files*, but the QML engine goes on serving the
component it already compiled, so a change needs `omarchy restart shell`. The
push script does that for you.

Edit the copy under `~/.config/omarchy/plugins/delarosa.headphones/` and run
`./scripts/sync-plugin.sh` to bring it back here.

The panel takes battery and connected state from BlueZ through
`Quickshell.Bluetooth`, so the widget still works with the daemon stopped --
it dims the mode buttons and offers to start it. Noise control is the only
part that needs the session.

## Facts worth keeping

- **The WH-1000XM5 answers on `956C7B26-D49A-4BA8-B03F-B17D393CB6E2`.** The
  classic MDR UUID fails with "Failed to get RFCOMM service channel", and neither
  vendor UUID the device advertises over SDP is the right one. Found by brute
  force over the UUIDs in the upstream source.
- **Only one control session at a time.** Stop the GUI client
  (`systemctl --user stop shc`) and close Sony's phone app first, or the
  handshake hangs.
- Connecting is asynchronous: poll until it stops reporting progress, then do
  the protocol handshake.

## Status

Working: the daemon, the CLI, and the Omarchy bar widget with its popup.
Verified: battery and mode readout, the stopped-daemon fallback, and recovery
when the daemon comes back. Not yet verified by ear: the mode buttons and the
ambient slider in the popup.

Reading works. `./tools/probe.py` reports the real battery level, and
`./tools/dump.py` returns data from every endpoint the device supports.

**The handshake completing does not mean the state has arrived.** Reading
immediately gives zeroes; values land over the following second or two. So
`open()` now issues a sync and pumps events for a couple of seconds before
returning. This was the cause of the "0% battery" that first looked like a
struct bug.

`charging` is an enum, not a boolean — 1 means *not* charging. Reading it as
truthy reports every idle headphone as charging.

### What the device answers (WH-1000XM5)

| Endpoint | State |
|---|---|
| Batteries | works — main, level, charging |
| NoiseControl | read and write both work; the echo does not (see below) |
| Equalizer, EqualizerBands | works — 5 bands |
| Playback, Power, Listening, SpeakToChat | return data |
| VoiceGuidance, ConnectionMode | single byte each |
| PairedDevices | works — 6 devices with MAC and name |
| Model, GeneralSettingInfo | return data |
| Pairing, SafeListening | empty |
| AssignableControls | "Not supported" |

Use `./tools/dump.py --expect N` to map an unknown field: it flags any byte
close to a value you can verify on the headphones themselves.

### Noise control: reads and writes both work, but do not confirm each other

The struct decodes cleanly from the header and matches what the headphones
report.

**Writing works in both directions.** Both `cancelling -> ambient` and
`ambient -> cancelling` were confirmed audibly by the person wearing them. The
state also survives disconnecting and reconnecting, so it is stored on the
device.

**Reading works too, for changes made on the headphones.** `tools/watch.py`
held the link while the button was pressed nine times, and every transition
appeared within one to three seconds.

**But a session is not reliably told about its own writes.** After writing a
mode, the cached state often keeps reporting the old one — for a full 60
seconds in one case, while the headphones had audibly changed. This is what
made a working write look like a rejected one, twice, and it is the single
biggest trap in this API.

Consequences for anything built on top:

- never block on a read-back to confirm a write; treat a successful `set` plus
  `commit` as done
- to verify the true state after writing, reconnect — a fresh session always
  reads correctly
- a widget should show the mode it just requested, and let the event stream
  correct it if the user presses the button

Recovery if a device is left in the wrong mode: the button on the headphones
cycles modes, per `button_mode`.

How the daemon lives with it: after a write it keeps showing the mode it asked
for, and goes back to believing the device only once the device's own reading
*moves*. A value that moves is the only evidence it has something new to say;
a value that sits still is exactly what a stale cache looks like. Press the
button and the widget follows within seconds. Until then the mode is shown with
a `?` -- almost certainly in effect, just not acknowledged.

Still unexplained: why self-initiated changes are not echoed while button
presses are. `mdrHeadphonesSetPacketCallback` exists for watching the wire and
would answer it. Worth doing for curiosity; nothing is waiting on it.

## Next

- the popup's mode buttons and ambient slider need one test with the
  headphones on a head
- the popup's "Start mdrctld" button is the one control not exercised yet
- equalizer is readable and untouched
- focus-on-voice is read but not writable from the popup
