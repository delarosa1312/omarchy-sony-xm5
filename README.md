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

    ./tools/probe.py          # connect, print state, disconnect
    ./tools/uuid_scan.py MAC  # find the service UUID of another Sony device

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
| NoiseControl | read fully decoded; writes only half-proven (see below) |
| Equalizer, EqualizerBands | works — 5 bands |
| Playback, Power, Listening, SpeakToChat | return data |
| VoiceGuidance, ConnectionMode | single byte each |
| PairedDevices | works — 6 devices with MAC and name |
| Model, GeneralSettingInfo | return data |
| Pairing, SafeListening | empty |
| AssignableControls | "Not supported" |

Use `./tools/dump.py --expect N` to map an unknown field: it flags any byte
close to a value you can verify on the headphones themselves.

### Noise control: reading solved, writing is asymmetric

The struct decodes cleanly from the header — mode, ambient level, focus on
voice, button behaviour, adaptive ambient and its sensitivity — and matches
what the headphones report.

Writing **reaches the device and is audible**, confirmed by ear:

- `cancelling -> ambient` works. The wearer hears it. The state also survives
  disconnecting and reconnecting the control session, so it is written to the
  headphones rather than held in the library.
- `ambient -> cancelling` does **not** work. `set` and `commit` both return OK
  and the dirty flag sets, but the device never echoes the new mode and the
  sound does not change — verified by polling for a full 60 seconds.

So the earlier "maybe it applies late" theory is dead, and so is "it reverts
when the session drops". The asymmetry is real.

Note the echo is slow even when it works: after a successful write the device
kept reporting the old mode for several seconds before updating. Any confirm
loop needs to be patient, and the daemon should stream state rather than block
on a write.

Recovery if a device is left in the wrong mode: the button on the headphones
cycles modes, per `button_mode`.

Ideas to try next, in order: send `mode = off` before `cancelling`; check
whether `ambient_level` or `focus_on_voice` must be cleared when leaving
ambient; compare against the packets the GUI client sends for the same change
(`mdrHeadphonesSetPacketCallback` exists for exactly this).

Then a daemon holding the link plus a thin CLI (`mdrctl watch`), then the bar
widget.
