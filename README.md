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

Working: build, connect, handshake, session lifecycle.

Not yet trustworthy: battery readings come back as 0% while reporting charging,
which looks like a struct layout mistake rather than real data. The field offsets
in `lib/mdr.py` need checking against `mdr-c/Headphones.h`.

Next: verify the readable fields, add the setters worth having, then a daemon
that holds the link plus a thin CLI, and finally the bar widget on top.
