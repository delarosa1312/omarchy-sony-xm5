# mdrctl

Control Sony MDR headphones from Linux, with the aim of driving them from a
small Omarchy bar widget rather than Sony's app.

Written against a **WH-1000XM5** and a **WF-1000XM5**, which are the only two
devices any of this has been run on. Devices are found by the MDR service they
advertise rather than by a list of addresses, and every control is gated on
what the device says it supports, so another Sony model has a fair chance of
working -- but nobody has tried one, and the notes below describe those two.

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

    ./scripts/install.sh

Builds `libmdr` and installs the two user services. Needs `cmake`, `ninja`, a
C++20 compiler, the BlueZ and D-Bus development files, and `bluez-utils` for
`mpris-proxy`. The upstream GUI is not built.

The unit carries `@MDRCTLD@` rather than a path, and the installer fills in
wherever you cloned this: a path baked into a repository is right for exactly
one machine.

## Use

    bin/mdrctl status                    # what the headphones are doing
    bin/mdrctl watch                     # follow changes live
    bin/mdrctl mode ambient              # off | cancelling | ambient
    bin/mdrctl ambient 15                # ambient, level 0-20
    bin/mdrctl cycle                     # next mode; what a bar click runs

There is no address to configure. The daemon takes whichever connected device
offers the MDR service, so a second Sony pair works the first time it is put
on. Set `MDR_MAC` only to pin it to one, which matters solely when two are
connected at once.

    ./scripts/test                       # no headphones required

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
       +── bar/omarchy-sony-xm5   a plain Waybar-JSON script, kept as a
                                    fallback for bars without a plugin system

The panel holds one socket to the daemon: commands go down it, and the daemon
pushes state back up it on every change, so nothing polls. Measured, a command
reaches the panel in about 19 ms through the CLI and under a millisecond over
the panel's own socket. It used to take between a third of a second and a
second and a half, spread across a process spawn per click, a 200 ms settle
inside each write, a half-second publish tick and a 700 ms poll.

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
    omarchy plugin enable io.github.delarosa1312.sony-xm5

The shell hot-reloads plugin *files*, but the QML engine goes on serving the
component it already compiled, so a change needs `omarchy restart shell`. The
push script does that for you.

Edit the copy under `~/.config/omarchy/plugins/io.github.delarosa1312.sony-xm5/` and run
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

## The widget

The Omarchy bar widget lives in `shell-plugin/` and is published separately, at
[omarchy-sony-xm5](https://github.com/delarosa1312/omarchy-sony-xm5) -- the
marketplace clones a repository and reads `manifest.json` at its root, so it
cannot sit in a subdirectory of this one.

    ./scripts/sync-plugin.sh push    # repo -> the live plugin, and reload
    ./scripts/sync-plugin.sh pull    # the live plugin -> repo
    ./scripts/publish-plugin.sh      # test, then push it to its own repo

`publish-plugin.sh` rebuilds that repository's history from the plugin's
commits here, so there is one place to edit and no second copy to keep level
by hand.

## Tests

    ./scripts/test

`tests/test_mdrctl.py` covers the things that were wrong once: the equaliser's
two halves staged before a single commit, discovery picking a connected
MDR device and nothing else, a claimed value surviving the device's own late
echo of it, and which battery stands for a pair of earbuds.

`tests/model.test.js` covers the panel's own logic, which lives in
`shell-plugin/Model.js` for exactly that reason -- extracting it immediately
turned up a bug where the earbud readings were printed in whatever order the
device answered in.

Neither needs headphones, BlueZ or libmdr, because none of those bugs were
hardware problems -- and none of them were visible in the panel either, which
is the point. The script also runs `omarchy plugin validate` and `qmllint`.

## Status

Working: the daemon, the CLI, and the Omarchy bar widget with its popup.

Verified: battery and mode readout, the stopped-daemon fallback, recovery when
the daemon returns, and equalizer band and clear-bass writes (by reconnect).
Confirmed earlier by ear: noise-mode writes.

Unverified: the ambient slider, connection mode, auto power off, auto pause and
shutdown. Each needs one reconnect test.

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

| Endpoint | Read | Write |
|---|---|---|
| Batteries | main, level, charging | — |
| NoiseControl | fully decoded | **works** (confirmed by ear, survives a reconnect) |
| EqualizerBands + clear bass | 5 bands, -10..+10 | **works** (verified by reconnect) |
| Equalizer preset | works | **accepted and ignored** |
| ConnectionMode | quality / stability | **acknowledged and ignored** |
| Power | auto power off, wearing, auto pause | auto pause **works**; auto power off **acknowledged and ignored**; shutdown **works** |
| Listening | returns data | feature probe says *unavailable* on the XM5 |
| PairedDevices | 6 devices with MAC and name | not wired up |
| SpeakToChat, VoiceGuidance | return data | not wired up |
| Model, GeneralSettingInfo | return data | — |
| Pairing, SafeListening | empty | — |
| AssignableControls | "Not supported" | — |

### Ask what the device supports, do not just write to it

`mdrHeadphonesGetFeature` answers per feature, and it matters more than it
looks: a write to an endpoint the device never advertised is validated,
staged, committed to the library's own copy of the state, and **never put on
the wire**. It returns success. A later read returns the value you wrote,
because you are reading the library's copy. Only a fresh session reveals that
the device never heard about it.

On this WH-1000XM5: `listening_mode`, `adaptive_ambient` and `head_gesture`
come back *unavailable*; equalizer, DSEE, connection mode, auto power off,
wearing detection, auto pause, speak-to-chat and shutdown come back
*available*. The widget hides anything unavailable rather than offering a
control that cannot work.

### The device does acknowledge every command

`mdrHeadphonesSetPacketCallback` exposes the wire, and a frame is
`[start][data type][seq][len:4][payload][checksum][end]`. Type 1 inbound is an
ACK. One clear-bass write looks like this:

    TX type 12   our command
    RX type 1    the device acknowledging it
    RX type 12   the device sending the new state back
    TX type 1    us acknowledging that

So writes were never unverifiable -- the answer was there from the first day
and nothing was listening. The daemon now counts ACKs, ties each to the write
it followed, and publishes `unacknowledged` for anything that got none.

An ACK means the command **arrived**, not that the device honoured it: a preset
write is acknowledged and ignored. Silence is the real failure signal.

A command that goes unanswered is resent with the sequence bit flipped, and the
library waits a full second before each retry -- the `FIXME-ACK Timeout` lines
in `journalctl --user -u mdrctld`. The daemon counts those as `retransmits`.
Every one observed so far succeeded on the second attempt, which points at a
sequence-number desync rather than a flaky link. Not yet explained.

### How to tell whether a write actually landed

Reconnect and read. A fresh session reads the device; the session that wrote
reads its own optimism. This is the only honest test, it needs no one wearing
the headphones, and it is how everything marked "works" above was checked:

    mdrctl clear-bass -3
    systemctl --user restart mdrctld    # fresh session
    mdrctl status                       # did it keep it?

### Equalizer: bands and clear bass are one message

Clear bass is the first element of the band array on the wire, which has two
consequences, both found by watching values drift:

- a clear-bass-only change is staged, committed locally and **never sent** --
  the library only builds the message when bands are staged too
- a bands-only change sends whatever clear bass was last staged, so clear bass
  slides by a step every time you touch the bands

`write_eq()` therefore always restates both. That is what makes either stick.

Preset is a separate message and is sent unconditionally, yet the device
ignores it: tested with two different presets, each checked from a fresh
session. So the widget shows the preset and does not offer to change it.

**Connection priority and the auto-power-off timer behave the same way.** The
frame goes out, the device acknowledges it within 25 ms, and a fresh session
still reads the old value. Three controls now known to be accepted and
discarded -- presets, connection priority, auto power off -- all shown
read-only. An ACK really does mean only that the command arrived.

Do not take a read-back from the writing session as evidence: the library
commits the value to its own copy whether or not the device honoured it. The
auto-power-off timer looked like it worked for exactly that reason.

### A session object is not a link

The library answers every read from its own cache, with no error, long after
the headphones have been switched off. So `mdrctld` went on publishing a live
headset -- full battery, mode, equaliser -- with nothing on the other end, and
the widget went on offering controls for it. Nothing in the MDR API reports
this; BlueZ is the one that knows. The daemon now asks it every few seconds
while it believes it has a session, and drops the session when the device goes
away.

### QML has no five-hex escape

`"\\U000f00af"` is not an escape sequence in QML -- it renders as that literal
text, which is exactly what the icon buttons showed. Only `\\uXXXX` (four hex)
works, and every glyph worth having here lives above U+FFFF. Write the
character itself into the file, as Omarchy's own panels do. This has now cost
two rounds; the giveaway is a button reading `U000f00af`.

### Seeing the headset's other connections

`mdrHeadphonesGetPairedDevices` returns what the headset itself is talking to,
which is the only way to see the phone: BlueZ knows about our link and nothing
about the headset's others. `mdrHeadphonesSetPairedDevice` connects,
disconnects, selects the playback device, or unpairs one, by MAC.

`mdrHeadphonesGetGeneralSettingInfo` lists the device's named on/off settings,
with `mdrHeadphonesGetText` giving each a name. On the WH-1000XM5 there are
exactly two, both writable: `TOUCH_PANEL_SETTING` and `MULTIPOINT_SETTING`.
The touch panel one matters more than it looks -- taking the headphones off
brushes the panel and sends a stray track-skip.

One trap when listing: the headset counts *this machine* among its connections,
so the local adapter's own address has to be excluded or the PC shows up as
another device.

### One control channel across every paired device

The headset grants one MDR session, and that is shared with whatever else it is
connected to. With multipoint on and a phone attached, the connect can fail with
either EBUSY or "Timed out Connecting to remote device" while A2DP audio keeps
working perfectly. Sony's app does not need to be open for the phone to be
holding it.

A failed connect must tear its half-open connection down. Leaving it holds an
RFCOMM socket, and the next attempt then fails against our own leftovers, so one
failure becomes permanent failure. `/proc/net/rfcomm` should show no sockets for
your user while the daemon has no session.

### Switching off needs a settle, uniquely

Every other write can leave its frame for the session's own loop to flush.
`shutdown` cannot: it is followed by tearing the session down, so with no
pumping the command never leaves the machine. That is exactly why the "switch
off" button did nothing.

### Auto power off is one setting, not two

On a device with wearing detection the library ignores the minutes entirely
and stages "power off when removed from ears" instead. Offering "switch off
after N minutes" and "power off when removed" as independent controls produces
a write that looks lost. They are alternatives: when removed, never, or one of
5 / 15 / 30 / 60 / 180 minutes.

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

- connection mode, auto power off, auto pause and shutdown are wired up but
  unproven; reconnect-test each before trusting it
- the popup's "Start mdrctld" button is not exercised yet
- why the device ignores a preset write is unexplained
- focus-on-voice is read but not writable from the popup
- `mdrHeadphonesSetPacketCallback` would show which of our writes actually
  reach the wire, and settle both the preset mystery and the missing echo
