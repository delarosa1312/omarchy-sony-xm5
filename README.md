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

### Noise control: reading solved, writing not yet

The struct decodes cleanly from the header — mode, ambient level, focus on
voice, button behaviour, adaptive ambient and its sensitivity — and matches
what the headphones report.

Writing is **not trustworthy yet**:

- cancelling -> ambient is accepted and echoed back by the device, reliably
- ambient -> cancelling was accepted (`set` and `commit` both return OK, the
  dirty flag sets) but the device did not echo the new mode back within ten
  seconds, twice

Between sessions the headphones were found back on cancelling, so the write may
apply late, or the mode may revert when the control session drops, or it was
changed by the button on the headphones. Not yet distinguished.

Until that is understood, do not rely on `set_noise_mode`, and do not run it
against headphones someone is wearing without telling them first.

Next: work out why the reverse write does not confirm — likely candidates are
an extra required field, a commit that needs different sequencing, or a stale
cached read. Then a daemon holding the link plus a thin CLI (`mdrctl watch`),
then the bar widget.
