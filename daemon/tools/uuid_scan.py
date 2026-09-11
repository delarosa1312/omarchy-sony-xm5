#!/usr/bin/env python3
"""Find which service UUID a device answers on.

Kept because this is what identified the XM5's UUID, and a different Sony model
will likely need it again.
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
import mdr

CANDIDATES = [
    "956C7B26-D49A-4BA8-B03F-B17D393CB6E2",  # works for WH-1000XM5
    "96CC203E-5068-46AD-B32D-E316F5E069BA",  # classic MDR
    "5B833E20-6BC7-4802-8E9A-723CECA4BD8F",
]

MAC = mdr.device_address(sys.argv[1] if len(sys.argv) > 1 else None)
BUILD = os.environ.get(
    "MDR_BUILD",
    os.path.join(os.path.dirname(__file__), "..", "..", "vendor", "SonyHeadphonesClient", "build"),
)

lib = mdr.Library(BUILD)
for uuid in CANDIDATES:
    try:
        with mdr.Headphones(lib, MAC, uuid=uuid):
            print(f"{uuid}  WORKS")
            break
    except mdr.MDRError as e:
        print(f"{uuid}  {e}")
