"""ctypes bindings for libmdr's C ABI.

The upstream project (MIT) splits the Sony MDR protocol into a library and a GUI
on top of it. We use only the library, so there is no fork to maintain and no
third-party code running inside the Omarchy shell.

Hard-won detail: the WH-1000XM5 answers on service UUID
956C7B26-D49A-4BA8-B03F-B17D393CB6E2. The classic MDR UUID (96CC203E-...) fails
with "Failed to get RFCOMM service channel", and neither UUID the device
advertises over SDP is the right one.

Only one control session may exist at a time. Stop the GUI client, and close
Sony's phone app, or the handshake never completes.
"""
import ctypes as C
import time

ABI_VERSION = 1
PROTOCOL_V1 = 1
PROTOCOL_V2 = 2

RESULT_OK = 0
RESULT_INPROGRESS = 1

XM5_SERVICE_UUID = "956C7B26-D49A-4BA8-B03F-B17D393CB6E2"

# mdr-c/Headphones.h
BATTERY_PART = {0: "main", 1: "left", 2: "right", 3: "case"}
# Not a boolean: 1 means *not* charging. Reading it as truthy reports every
# idle headphone as charging.
CHARGING = {0: "unknown", 1: "no", 2: "yes", 3: "complete"}


class Battery(C.Structure):
    # Layout verified against mdr-c/Headphones.h.
    _fields_ = [
        ("part", C.c_uint32),
        ("present", C.c_uint32),
        ("level_percent", C.c_uint8),
        ("update_threshold_percent", C.c_uint8),
        ("charging", C.c_uint32),
    ]


class MDRError(RuntimeError):
    pass


class Library:
    """Loads the two shared objects and declares the calls we use."""

    def __init__(self, build_dir):
        p = C.c_void_p
        self.mdr = C.CDLL(f"{build_dir}/libmdr/src/libmdr-shared.so", mode=C.RTLD_GLOBAL)
        self.bt = C.CDLL(f"{build_dir}/libmdr-bt/src/libmdr-bt-shared.so", mode=C.RTLD_GLOBAL)

        def sig(lib, name, restype, *argtypes):
            fn = getattr(lib, name)
            fn.restype, fn.argtypes = restype, list(argtypes)
            return fn

        u32 = C.c_uint32
        self.conn_create = sig(self.bt, "mdrConnectionLinuxCreate", p)
        self.conn_get = sig(self.bt, "mdrConnectionLinuxGet", p, p)
        self.conn_destroy = sig(self.bt, "mdrConnectionLinuxDestroy", None, p)
        self.connect = sig(self.mdr, "mdrConnectionConnect", u32, p, C.c_char_p, C.c_char_p)
        self.disconnect = sig(self.mdr, "mdrConnectionDisconnect", None, p)
        self.conn_poll = sig(self.mdr, "mdrConnectionPoll", u32, p, C.c_int)
        self.last_error = sig(self.mdr, "mdrConnectionGetLastError", C.c_char_p, p)
        self.hp_create = sig(self.mdr, "mdrHeadphonesCreate", u32, u32, p, u32, C.POINTER(p))
        self.hp_destroy = sig(self.mdr, "mdrHeadphonesDestroy", None, p)
        self.hp_init = sig(self.mdr, "mdrHeadphonesRequestInit", u32, p)
        self.hp_sync = sig(self.mdr, "mdrHeadphonesRequestSync", u32, p)
        self.hp_commit = sig(self.mdr, "mdrHeadphonesRequestCommit", u32, p)
        self.hp_poll = sig(self.mdr, "mdrHeadphonesPoll", u32, p, p)
        self.hp_ready = sig(self.mdr, "mdrHeadphonesIsReady", u32, p)
        self.hp_dirty = sig(self.mdr, "mdrHeadphonesIsDirty", u32, p)
        self.batteries = sig(self.mdr, "mdrHeadphonesGetBatteries", u32, p,
                             C.POINTER(Battery), C.POINTER(u32))
        self._result_string = sig(self.mdr, "mdrResultString", C.c_char_p, u32)

    def result(self, code):
        s = self._result_string(code)
        return s.decode() if s else f"code {code}"


class Headphones:
    """One control session. Use as a context manager."""

    def __init__(self, lib, mac, uuid=XM5_SERVICE_UUID, protocol=PROTOCOL_V2):
        self.lib, self.mac, self.uuid, self.protocol = lib, mac, uuid, protocol
        self._handle = self._conn = None
        self._hp = C.c_void_p()
        self._event = (C.c_ubyte * 512)()

    def __enter__(self):
        self.open()
        return self

    def __exit__(self, *_):
        self.close()

    def open(self, link_timeout=5.0, ready_timeout=10.0, settle=2.0):
        """Connect, handshake, then let state arrive.

        `settle` matters: the handshake completing only means the device is
        talking. Values such as battery level land afterwards, so reading
        immediately returns zeroes. Two seconds is enough in practice.
        """
        lib = self.lib
        self._handle = lib.conn_create()
        self._conn = lib.conn_get(self._handle)
        if not self._conn:
            raise MDRError("could not create a connection object")

        r = lib.connect(self._conn, self.mac.encode(), self.uuid.encode())
        if r not in (RESULT_OK, RESULT_INPROGRESS):
            raise MDRError(f"connect refused: {lib.result(r)}")

        # The connect is asynchronous: drive it until it stops reporting progress.
        deadline, state = time.monotonic() + link_timeout, RESULT_INPROGRESS
        while time.monotonic() < deadline:
            state = lib.conn_poll(self._conn, 100)
            if state != RESULT_INPROGRESS:
                break
        if state != RESULT_OK:
            err = lib.last_error(self._conn)
            raise MDRError(f"link failed: {lib.result(state)} {err.decode() if err else ''}".strip())

        r = lib.hp_create(ABI_VERSION, self._conn, self.protocol, C.byref(self._hp))
        if r != RESULT_OK:
            raise MDRError(f"could not create headphones object: {lib.result(r)}")

        lib.hp_init(self._hp)
        deadline = time.monotonic() + ready_timeout
        while time.monotonic() < deadline:
            self.pump()
            if lib.hp_ready(self._hp):
                break
        else:
            raise MDRError("headphones never became ready (is the app or phone holding the link?)")

        lib.hp_sync(self._hp)
        deadline = time.monotonic() + settle
        while time.monotonic() < deadline:
            self.pump(50)

    def pump(self, timeout_ms=100):
        """Drive both the socket and the protocol state machine once."""
        self.lib.conn_poll(self._conn, timeout_ms)
        self.lib.hp_poll(self._hp, C.cast(self._event, C.c_void_p))

    def get_batteries(self, maximum=4):
        count = C.c_uint32(maximum)
        buf = (Battery * maximum)()
        r = self.lib.batteries(self._hp, buf, C.byref(count))
        if r != RESULT_OK:
            raise MDRError(f"battery read failed: {self.lib.result(r)}")
        return [b for b in list(buf)[: count.value] if b.present]

    def close(self):
        if self._hp:
            self.lib.hp_destroy(self._hp)
            self._hp = C.c_void_p()
        if self._conn:
            self.lib.disconnect(self._conn)
        if self._handle:
            self.lib.conn_destroy(self._handle)
        self._handle = self._conn = None


def describe(battery):
    """Human-readable battery line, decoding the enums correctly."""
    part = BATTERY_PART.get(battery.part, f"part {battery.part}")
    state = CHARGING.get(battery.charging, f"state {battery.charging}")
    return f"{part}: {battery.level_percent}% (charging: {state})"
