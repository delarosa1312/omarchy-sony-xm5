#!/usr/bin/env python3
"""Connect once, print what we can read, disconnect. The smoke test."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
import mdr

MAC = os.environ.get("MDR_MAC", "00:00:5E:00:53:01")
BUILD = os.environ.get(
    "MDR_BUILD",
    os.path.join(os.path.dirname(__file__), "..", "vendor", "SonyHeadphonesClient", "build"),
)

lib = mdr.Library(BUILD)
with mdr.Headphones(lib, MAC) as hp:
    print(f"connected to {MAC}, handshake complete")
    for b in hp.get_batteries():
        print(f"  battery part={b.part} level={b.level_percent}% charging={bool(b.charging)}")
