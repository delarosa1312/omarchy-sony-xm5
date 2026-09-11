#!/usr/bin/env python3
"""Call every readable endpoint and dump raw bytes.

Rather than guessing each struct's layout from the header, ask for everything
into an oversized buffer and look at what comes back. Bytes close to a value you
can verify on the headphones themselves (battery percentage, say) are flagged,
which is how you find which field is which.

    ./tools/dump.py --expect 80
"""
import argparse, ctypes as C, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
import mdr

# (name, kind): "one" -> (hp, out*), "many" -> (hp, buf, inout_count)
GETTERS = [
    ("Model", "one"), ("Batteries", "many"), ("Playback", "one"),
    ("NoiseControl", "one"), ("SpeakToChat", "one"), ("Listening", "one"),
    ("Equalizer", "one"), ("EqualizerBands", "many"), ("Pairing", "one"),
    ("Power", "one"), ("VoiceGuidance", "one"), ("ConnectionMode", "one"),
    ("SafeListening", "one"), ("GeneralSettingInfo", "many"),
    ("AssignableControls", "many"), ("PairedDevices", "many"),
]

BUF = 512


def hexdump(data, width=16):
    out = []
    for i in range(0, len(data), width):
        chunk = data[i:i + width]
        out.append(f"    {i:04x}  " + " ".join(f"{b:02x}" for b in chunk))
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--expect", type=int, action="append", default=[],
                    help="value you know is true right now, e.g. battery percent")
    ap.add_argument("--mac", default=None)
    ap.add_argument("--settle", type=float, default=3.0,
                    help="seconds to pump events before reading")
    args = ap.parse_args()
    args.mac = mdr.device_address(args.mac)

    build = os.environ.get(
        "MDR_BUILD",
        os.path.join(os.path.dirname(__file__), "..", "vendor", "SonyHeadphonesClient", "build"))
    lib = mdr.Library(build)

    with mdr.Headphones(lib, args.mac) as hp:
        lib.hp_sync(hp._hp)
        import time
        end = time.monotonic() + args.settle
        while time.monotonic() < end:
            hp.pump(50)
        print(f"connected, settled for {args.settle}s\n")

        for name, kind in GETTERS:
            fn = getattr(lib.mdr, f"mdrHeadphonesGet{name}", None)
            if fn is None:
                print(f"{name}: not exported"); continue
            fn.restype = C.c_uint32
            buf = (C.c_ubyte * BUF)()
            if kind == "one":
                fn.argtypes = [C.c_void_p, C.c_void_p]
                r = fn(hp._hp, C.cast(buf, C.c_void_p))
                used = BUF
            else:
                fn.argtypes = [C.c_void_p, C.c_void_p, C.POINTER(C.c_uint32)]
                count = C.c_uint32(8)
                r = fn(hp._hp, C.cast(buf, C.c_void_p), C.byref(count))
                used = BUF
            data = bytes(buf)
            trimmed = data.rstrip(b"\x00") or b""
            status = lib.result(r)
            extra = f", count={count.value}" if kind == "many" else ""
            print(f"{name}: {status}{extra}, {len(trimmed)} non-zero bytes")
            if trimmed:
                print(hexdump(trimmed[:64]))
                for want in args.expect:
                    hits = [i for i, b in enumerate(trimmed) if abs(b - want) <= 2]
                    if hits:
                        vals = ", ".join(f"offset {i}=0x{trimmed[i]:02x}({trimmed[i]})" for i in hits[:6])
                        print(f"    ~{want} found at {vals}")
            print()


if __name__ == "__main__":
    main()
