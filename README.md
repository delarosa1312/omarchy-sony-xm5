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
| NoiseControl | returns data, fields not yet mapped |
| Equalizer, EqualizerBands | works — 5 bands |
| Playback, Power, Listening, SpeakToChat | return data |
| VoiceGuidance, ConnectionMode | single byte each |
| PairedDevices | works — 6 devices with MAC and name |
| Model, GeneralSettingInfo | return data |
| Pairing, SafeListening | empty |
| AssignableControls | "Not supported" |

Use `./tools/dump.py --expect N` to map an unknown field: it flags any byte
close to a value you can verify on the headphones themselves.

Next: map the NoiseControl fields (the ones the widget needs), add setters,
then a daemon holding the link plus a thin CLI (`mdrctl watch`), then the
bar widget.
