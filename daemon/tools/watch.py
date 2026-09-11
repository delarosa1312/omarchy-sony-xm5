#!/usr/bin/env python3
"""Hold the link open and report every state change, with timestamps.

Used to answer: does a session notice changes made on the headphones
themselves (button presses), and how quickly?
"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
import mdr

seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 60.0
build = os.environ.get(
    "MDR_BUILD",
    os.path.join(os.path.dirname(__file__), "..", "..", "vendor", "SonyHeadphonesClient", "build"))
lib = mdr.Library(build)

with mdr.Headphones(lib, mdr.device_address()) as hp:
    t0 = time.monotonic()
    last = None
    while time.monotonic() - t0 < seconds:
        hp.pump(100)
        now = mdr.describe_noise(hp.get_noise_control())
        if now != last:
            print(f"[{time.monotonic()-t0:6.1f}s] {now}", flush=True)
            last = now
    print(f"[{time.monotonic()-t0:6.1f}s] done", flush=True)
