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

AVAILABILITY = {0: "unknown", 1: "unavailable", 2: "available"}

PACKET_RX, PACKET_TX = 0, 1

def device_address(argv_value=None):
    """Which headphones a tool should talk to.

    There is no default. A real address baked into a repository belongs to one
    person's hardware, is of no use to anyone else, and is not theirs to
    publish -- the daemon finds the headphones by the service they advertise,
    and these tools take the address from the caller.
    """
    import os
    value = argv_value or os.environ.get("MDR_MAC", "")
    if not value:
        raise SystemExit(
            "no device given. Pass the address, or set MDR_MAC.\n"
            "  bluetoothctl devices Connected   lists what is connected now")
    return value.upper()


# Frame layout is [start][data type][seq][len:4][payload][checksum][end], so the
# type is the second byte. An inbound frame of type ACK is the device saying it
# received the last command -- the one real acknowledgement this protocol gives.
DATA_TYPE_ACK = 1

# mdrHeadphonesSetPairedDevice commands.
PAIRED_CONNECT, PAIRED_DISCONNECT, PAIRED_PLAYBACK, PAIRED_UNPAIR = 1, 2, 3, 4
PAIRED_COMMAND = {"connect": PAIRED_CONNECT, "disconnect": PAIRED_DISCONNECT,
                  "playback": PAIRED_PLAYBACK, "unpair": PAIRED_UNPAIR}

# The device exposes a short list of named on/off settings. On the WH-1000XM5
# that is the touch panel and multipoint; the names come back as symbols, not
# prose, so they are mapped here rather than shown raw.
GENERAL_SETTING_NAMES = {
    "TOUCH_PANEL_SETTING": "touch_panel",
    "MULTIPOINT_SETTING": "multipoint",
}

# Asking beats trying. A write to an unsupported endpoint is staged, committed
# and silently dropped -- the library only puts it on the wire if the device
# advertised support -- so an unsupported control looks exactly like a working
# one that the device chose to ignore.
FEATURE = {
    "noise_cancelling": 8, "ambient_sound": 9, "adaptive_ambient": 10,
    "speak_to_chat": 11, "listening_mode": 12, "equalizer": 13, "dsee": 14,
    "auto_power_off": 20, "wearing_detection": 21, "auto_pause": 22,
    "head_gesture": 23, "shutdown": 26, "connection_mode": 27,
}

XM5_SERVICE_UUID = "956C7B26-D49A-4BA8-B03F-B17D393CB6E2"

# mdr-c/Headphones.h
BATTERY_PART = {0: "main", 1: "left", 2: "right", 3: "case"}
# Not a boolean: 1 means *not* charging. Reading it as truthy reports every
# idle headphone as charging.
CHARGING = {0: "unknown", 1: "no", 2: "yes", 3: "complete"}

NOISE_MODE = {0: "off", 1: "cancelling", 2: "ambient"}
NOISE_MODE_BY_NAME = {v: k for k, v in NOISE_MODE.items()}
NOISE_BUTTON = {0: "none", 1: "nc/ambient/off", 2: "nc/ambient",
                3: "nc/off", 4: "ambient/off"}
ADAPTIVE_SENSITIVITY = {0: "unknown", 1: "low", 2: "standard", 3: "high"}

# Ambient level runs 0-20 on this family; 20 lets the most sound through.
AMBIENT_LEVEL_MAX = 20

EQ_PRESET = {
    0: "off", 1: "rock", 2: "pop", 3: "jazz", 4: "dance", 5: "edm",
    6: "r&b/hip-hop", 7: "acoustic", 8: "bright", 9: "excited", 10: "mellow",
    11: "relaxed", 12: "vocal", 13: "treble", 14: "bass", 15: "speech",
    16: "heavy", 17: "clear", 18: "hard", 19: "soft", 20: "gaming",
    21: "fps-1", 22: "fps-2", 23: "fps-3", 24: "custom",
    25: "user-1", 26: "user-2", 27: "user-3", 28: "user-4", 29: "user-5",
    255: "unknown",
}
EQ_PRESET_BY_NAME = {v: k for k, v in EQ_PRESET.items()}

# DSEE upscales compressed audio. Worth having on a service that tops out at
# 256 kbps; the device reports which generation of it the hardware implements.
DSEE = {0: "unknown", 1: "standard", 2: "hx", 3: "hx-ai", 4: "ultimate"}

# The LDAC lever: quality asks for the higher bitrate, stability drops it when
# the link is busy.
AUDIO_PRIORITY = {0: "unknown", 1: "quality", 2: "stability"}
AUDIO_PRIORITY_BY_NAME = {v: k for k, v in AUDIO_PRIORITY.items() if v != "unknown"}

LISTENING_MODE = {0: "standard", 1: "background-music", 2: "cinema"}
LISTENING_MODE_BY_NAME = {v: k for k, v in LISTENING_MODE.items()}
ROOM_SIZE = {0: "unknown", 1: "small", 2: "medium", 3: "large"}
ROOM_SIZE_BY_NAME = {v: k for k, v in ROOM_SIZE.items() if v != "unknown"}

WEARING_POWER = {0: "unavailable", 1: "disabled", 2: "when-removed"}
WEARING_POWER_BY_NAME = {v: k for k, v in WEARING_POWER.items() if v != "unavailable"}

# Auto power off is one setting with alternatives, not two independent ones:
# a device with wearing detection powers off when removed OR after N minutes of
# silence, never both. The library accepts only these minute values on V2.
AUTO_POWER_OFF_MINUTES = [5, 15, 30, 60, 180]
POWER_OFF_CHOICES = ["when-removed", "never"] + [str(m) for m in AUTO_POWER_OFF_MINUTES]


class Battery(C.Structure):
    # Layout verified against mdr-c/Headphones.h.
    _fields_ = [
        ("part", C.c_uint32),
        ("present", C.c_uint32),
        ("level_percent", C.c_uint8),
        ("update_threshold_percent", C.c_uint8),
        ("charging", C.c_uint32),
    ]


class NoiseControl(C.Structure):
    """mdr-c/Headphones.h. ambient_level is the only byte-sized field, so the
    compiler pads it out to the next word; ctypes lays it out identically."""
    _fields_ = [
        ("mode", C.c_uint32),
        ("ambient_level", C.c_uint8),
        ("changing_asm_level", C.c_uint32),
        ("focus_on_voice", C.c_uint32),
        ("button_mode", C.c_uint32),
        ("adaptive_ambient", C.c_uint32),
        ("adaptive_sensitivity", C.c_uint32),
    ]


class Equalizer(C.Structure):
    # mdr-c/Headphones.h. clear_bass is signed: it cuts as well as boosts.
    _fields_ = [
        ("preset", C.c_uint32),
        ("clear_bass", C.c_int8),
        ("band_count", C.c_uint32),
        ("dsee_enabled", C.c_uint32),
        ("dsee_type", C.c_uint32),
    ]


class ConnectionMode(C.Structure):
    _fields_ = [("audio_priority", C.c_uint32)]


class Power(C.Structure):
    _fields_ = [
        ("auto_power_off_minutes", C.c_uint32),
        ("wearing_power", C.c_uint32),
        ("auto_pause", C.c_uint32),
        ("head_gesture", C.c_uint32),
        # Write-only in practice: setting it asks the headphones to switch off.
        ("shutdown_requested", C.c_uint32),
    ]


class Listening(C.Structure):
    _fields_ = [
        ("mode", C.c_uint32),
        ("background_room", C.c_uint32),
    ]


# void (*)(void* user, MDRPacketDirection, const unsigned char*, int)
PACKET_CALLBACK = C.CFUNCTYPE(None, C.c_void_p, C.c_uint32, C.POINTER(C.c_ubyte), C.c_int)


class GeneralSettingInfo(C.Structure):
    _fields_ = [("index", C.c_uint32), ("type", C.c_uint32), ("writable", C.c_uint32)]


class GeneralSetting(C.Structure):
    _fields_ = [("index", C.c_uint32), ("boolean_value", C.c_uint32)]


class PairedDevice(C.Structure):
    # mdr-c/Headphones.h. `connected` is this device's own view of who it is
    # talking to, which is the only way to see the phone from here.
    _fields_ = [
        ("connected", C.c_uint32),
        ("playback_device", C.c_uint32),
        ("mac", C.c_char * 18),
        ("name", C.c_char * 128),
    ]


class PairedDeviceAction(C.Structure):
    _fields_ = [
        ("command", C.c_uint32),
        ("device_id", C.c_char_p),
        ("device_id_size", C.c_uint32),
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
        self.get_noise = sig(self.mdr, "mdrHeadphonesGetNoiseControl", u32, p,
                             C.POINTER(NoiseControl))
        self.set_noise = sig(self.mdr, "mdrHeadphonesSetNoiseControl", u32, p,
                             C.POINTER(NoiseControl))
        self.get_eq = sig(self.mdr, "mdrHeadphonesGetEqualizer", u32, p,
                          C.POINTER(Equalizer))
        self.set_eq = sig(self.mdr, "mdrHeadphonesSetEqualizer", u32, p,
                          C.POINTER(Equalizer))
        self.get_eq_bands = sig(self.mdr, "mdrHeadphonesGetEqualizerBands", u32, p,
                                C.POINTER(C.c_int8), C.POINTER(u32))
        self.set_eq_bands = sig(self.mdr, "mdrHeadphonesSetEqualizerBands", u32, p,
                                C.POINTER(C.c_int8), u32)
        self.get_conn_mode = sig(self.mdr, "mdrHeadphonesGetConnectionMode", u32, p,
                                 C.POINTER(ConnectionMode))
        self.set_conn_mode = sig(self.mdr, "mdrHeadphonesSetConnectionMode", u32, p,
                                 C.POINTER(ConnectionMode))
        self.get_power = sig(self.mdr, "mdrHeadphonesGetPower", u32, p, C.POINTER(Power))
        self.set_power = sig(self.mdr, "mdrHeadphonesSetPower", u32, p, C.POINTER(Power))
        self.get_listening = sig(self.mdr, "mdrHeadphonesGetListening", u32, p,
                                 C.POINTER(Listening))
        self.set_listening = sig(self.mdr, "mdrHeadphonesSetListening", u32, p,
                                 C.POINTER(Listening))
        self.get_feature = sig(self.mdr, "mdrHeadphonesGetFeature", u32, p, u32,
                               C.POINTER(u32))
        self.set_packet_cb = sig(self.mdr, "mdrHeadphonesSetPacketCallback", None, p,
                                 PACKET_CALLBACK, p)
        self.get_setting_info = sig(self.mdr, "mdrHeadphonesGetGeneralSettingInfo", u32, p,
                                    C.POINTER(GeneralSettingInfo), C.POINTER(u32))
        self.get_setting = sig(self.mdr, "mdrHeadphonesGetGeneralSetting", u32, p, u32,
                               C.POINTER(GeneralSetting))
        self.set_setting = sig(self.mdr, "mdrHeadphonesSetGeneralSetting", u32, p,
                               C.POINTER(GeneralSetting))
        self.get_text = sig(self.mdr, "mdrHeadphonesGetText", u32, p, u32, u32,
                            C.c_char_p, C.POINTER(u32))
        self.get_paired = sig(self.mdr, "mdrHeadphonesGetPairedDevices", u32, p,
                              C.POINTER(PairedDevice), C.POINTER(u32))
        self.set_paired = sig(self.mdr, "mdrHeadphonesSetPairedDevice", u32, p,
                              C.POINTER(PairedDeviceAction))
        self._result_string = sig(self.mdr, "mdrResultString", C.c_char_p, u32)

    def result(self, code):
        s = self._result_string(code)
        return s.decode() if s else f"code {code}"


class Headphones:
    """One control session. Use as a context manager."""

    # How long a write pumps the protocol before returning. A one-shot caller
    # that closes straight after a write needs this, or the frame never leaves.
    # A long-lived session pumps anyway, so it sets this to zero and saves the
    # wait on every single action.
    write_settle = 0.2

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
            self.close()
            raise MDRError(f"connect refused: {lib.result(r)}")

        # The connect is asynchronous: drive it until it stops reporting progress.
        deadline, state = time.monotonic() + link_timeout, RESULT_INPROGRESS
        while time.monotonic() < deadline:
            state = lib.conn_poll(self._conn, 100)
            if state != RESULT_INPROGRESS:
                break
        if state != RESULT_OK:
            err = lib.last_error(self._conn)
            message = f"link failed: {lib.result(state)} {err.decode() if err else ''}".strip()
            # Tear the half-open connection down before giving up. Leaving it
            # holds an RFCOMM socket open, and the next attempt then fails with
            # EBUSY against our own leftovers -- one failure turning into
            # permanent failure.
            self.close()
            raise MDRError(message)

        r = lib.hp_create(ABI_VERSION, self._conn, self.protocol, C.byref(self._hp))
        if r != RESULT_OK:
            self.close()
            raise MDRError(f"could not create headphones object: {lib.result(r)}")

        lib.hp_init(self._hp)
        deadline = time.monotonic() + ready_timeout
        while time.monotonic() < deadline:
            self.pump()
            if lib.hp_ready(self._hp):
                break
        else:
            self.close()
            raise MDRError("headphones never became ready (is another device holding the link?)")

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

    def get_noise_control(self):
        nc = NoiseControl()
        r = self.lib.get_noise(self._hp, C.byref(nc))
        if r != RESULT_OK:
            raise MDRError(f"noise control read failed: {self.lib.result(r)}")
        return nc

    def set_noise_control(self, nc, settle=None):
        """Write a noise-control state and commit it.

        Deliberately does not wait for a read-back. A session is not reliably
        told about its own writes -- the cached value can keep reporting the old
        mode for a minute while the headphones have audibly changed -- so
        waiting for confirmation turns a write that worked into an error. The
        write landing is the success; pump briefly to get it onto the wire.
        """
        r = self.lib.set_noise(self._hp, C.byref(nc))
        if r != RESULT_OK:
            raise MDRError(f"noise control write failed: {self.lib.result(r)}")
        self.lib.hp_commit(self._hp)
        deadline = time.monotonic() + (self.write_settle if settle is None else settle)
        while time.monotonic() < deadline:
            self.pump(20)
        return nc

    def set_noise_mode(self, mode, ambient_level=None):
        """mode: 'off', 'cancelling' or 'ambient'."""
        if isinstance(mode, str):
            if mode not in NOISE_MODE_BY_NAME:
                raise ValueError(f"mode must be one of {sorted(NOISE_MODE_BY_NAME)}")
            mode = NOISE_MODE_BY_NAME[mode]
        nc = self.get_noise_control()
        nc.mode = mode
        if ambient_level is not None:
            nc.ambient_level = max(0, min(AMBIENT_LEVEL_MAX, int(ambient_level)))
        return self.set_noise_control(nc)

    def watch_packets(self, fn):
        """Call fn(direction, frame_bytes) for every frame on the wire.

        Runs inside the library's parsing, so it must do almost nothing. The
        reference has to be kept alive on the instance or ctypes will collect
        the thunk and the library will call into freed memory.
        """
        def trampoline(_user, direction, frame, size):
            try:
                fn(int(direction), bytes(bytearray(frame[:size])))
            except Exception:
                pass                      # never let an exception cross the ABI
        self._packet_cb = PACKET_CALLBACK(trampoline)
        self.lib.set_packet_cb(self._hp, self._packet_cb, None)

    TEXT_GENERAL_SETTING_SUBJECT = 11

    def text(self, kind, index, size=256):
        buf = C.create_string_buffer(size)
        n = C.c_uint32(size)
        if self.lib.get_text(self._hp, kind, index, buf, C.byref(n)) != RESULT_OK:
            return ""
        return buf.value.decode(errors="replace")

    def general_settings(self, maximum=16):
        """The device's named on/off settings, keyed by our own short names."""
        count = C.c_uint32(maximum)
        buf = (GeneralSettingInfo * maximum)()
        if self.lib.get_setting_info(self._hp, buf, C.byref(count)) != RESULT_OK:
            return {}
        out = {}
        for info in list(buf)[: count.value]:
            subject = self.text(self.TEXT_GENERAL_SETTING_SUBJECT, info.index)
            name = GENERAL_SETTING_NAMES.get(subject)
            if not name:
                continue
            setting = GeneralSetting()
            if self.lib.get_setting(self._hp, info.index, C.byref(setting)) != RESULT_OK:
                continue
            out[name] = {"index": int(info.index),
                         "value": bool(setting.boolean_value),
                         "writable": bool(info.writable)}
        return out

    def set_general_setting(self, index, value, settle=None):
        setting = GeneralSetting(index=int(index), boolean_value=1 if value else 0)
        r = self.lib.set_setting(self._hp, C.byref(setting))
        if r != RESULT_OK:
            raise MDRError(f"setting write failed: {self.lib.result(r)}")
        self.lib.hp_commit(self._hp)
        deadline = time.monotonic() + (self.write_settle if settle is None else settle)
        while time.monotonic() < deadline:
            self.pump(20)
        return value

    def paired_devices(self, maximum=16):
        count = C.c_uint32(maximum)
        buf = (PairedDevice * maximum)()
        r = self.lib.get_paired(self._hp, buf, C.byref(count))
        if r != RESULT_OK:
            raise MDRError(f"paired device read failed: {self.lib.result(r)}")
        return [{"mac": d.mac.decode(errors="replace"),
                 "name": d.name.decode(errors="replace"),
                 "connected": bool(d.connected),
                 "playback": bool(d.playback_device)}
                for d in list(buf)[: count.value]]

    def paired_device_action(self, command, mac, settle=None):
        """connect / disconnect / playback / unpair, by MAC."""
        if isinstance(command, str):
            if command not in PAIRED_COMMAND:
                raise ValueError(f"command must be one of {sorted(PAIRED_COMMAND)}")
            command = PAIRED_COMMAND[command]
        raw = mac.encode()
        action = PairedDeviceAction(command=command, device_id=raw, device_id_size=len(raw))
        r = self.lib.set_paired(self._hp, C.byref(action))
        if r != RESULT_OK:
            raise MDRError(f"paired device action failed: {self.lib.result(r)}")
        self.lib.hp_commit(self._hp)
        deadline = time.monotonic() + (self.write_settle if settle is None else settle)
        while time.monotonic() < deadline:
            self.pump(20)
        return True

    def feature(self, name):
        """'available', 'unavailable' or 'unknown'."""
        if name not in FEATURE:
            raise ValueError(f"unknown feature {name!r}")
        out = C.c_uint32(0)
        r = self.lib.get_feature(self._hp, FEATURE[name], C.byref(out))
        if r != RESULT_OK:
            return "unknown"
        return AVAILABILITY.get(out.value, "unknown")

    def features(self):
        return {name: self.feature(name) for name in FEATURE}

    # ---- equalizer ----------------------------------------------------

    def get_equalizer(self):
        eq = Equalizer()
        r = self.lib.get_eq(self._hp, C.byref(eq))
        if r != RESULT_OK:
            raise MDRError(f"equalizer read failed: {self.lib.result(r)}")
        return eq

    def set_equalizer(self, eq, settle=None):
        """Writes are fire-and-forget, for the same reason as noise control:
        the device does not echo a session's own changes back to it."""
        r = self.lib.set_eq(self._hp, C.byref(eq))
        if r != RESULT_OK:
            raise MDRError(f"equalizer write failed: {self.lib.result(r)}")
        self.lib.hp_commit(self._hp)
        deadline = time.monotonic() + (self.write_settle if settle is None else settle)
        while time.monotonic() < deadline:
            self.pump(20)
        return eq

    def _eq_for_write(self):
        """The struct read back is not safe to write straight home.

        The library rejects a band_count that is neither 0 nor exactly the
        current one, and a dsee_type that is neither 0 nor exactly the current
        one. Zero means "leave it alone" for both, and bands are written
        through set_equalizer_bands anyway, so zero both before writing.
        """
        eq = self.get_equalizer()
        eq.band_count = 0
        eq.dsee_type = 0
        return eq

    def set_eq_preset(self, preset):
        if isinstance(preset, str):
            if preset not in EQ_PRESET_BY_NAME:
                raise ValueError(f"preset must be one of {sorted(EQ_PRESET_BY_NAME)}")
            preset = EQ_PRESET_BY_NAME[preset]
        eq = self._eq_for_write()
        eq.preset = preset
        return self.set_equalizer(eq)

    def set_dsee(self, enabled):
        eq = self._eq_for_write()
        eq.dsee_enabled = 1 if enabled else 0
        return self.set_equalizer(eq)

    def write_eq(self, bands=None, clear_bass=None, settle=None):
        """Write bands and clear bass together, because the device does.

        They share one message: clear bass is the first element of the band
        array on the wire. Three things follow, each learned the hard way.

        A clear-bass-only change is staged, committed locally and never sent --
        the library only builds that message when bands are staged too. A
        bands-only change sends whatever clear bass was last staged, so clear
        bass drifts a step every time you touch the bands. And committing
        between the two stages flushes the message with only half the change
        in it: the frame goes out carrying the *old* bands, which looks exactly
        like the device ignoring the write.

        So stage both, then commit once.
        """
        values = self.get_equalizer_bands() if bands is None else [int(v) for v in bands]
        limit = self.BAND_LIMITS.get(len(values))
        if limit is None:
            raise ValueError("the device takes exactly 5 or 10 bands")
        if any(abs(v) > limit for v in values):
            raise ValueError(f"{len(values)} bands run from -{limit} to +{limit}")

        eq = self._eq_for_write()
        if clear_bass is not None:
            clear_bass = int(clear_bass)
            if not -10 <= clear_bass <= 10:
                raise ValueError("clear bass runs from -10 to +10")
            eq.clear_bass = clear_bass

        r = self.lib.set_eq(self._hp, C.byref(eq))
        if r != RESULT_OK:
            raise MDRError(f"equalizer write failed: {self.lib.result(r)}")
        buf = (C.c_int8 * len(values))(*values)
        r = self.lib.set_eq_bands(self._hp, buf, len(values))
        if r != RESULT_OK:
            raise MDRError(f"equalizer band write failed: {self.lib.result(r)}")

        self.lib.hp_commit(self._hp)
        deadline = time.monotonic() + (self.write_settle if settle is None else settle)
        while time.monotonic() < deadline:
            self.pump(20)
        return values

    def set_clear_bass(self, level):
        return self.write_eq(clear_bass=level)

    def set_bands(self, values):
        return self.write_eq(bands=values)

    def get_equalizer_bands(self, maximum=16):
        count = C.c_uint32(maximum)
        buf = (C.c_int8 * maximum)()
        r = self.lib.get_eq_bands(self._hp, buf, C.byref(count))
        if r != RESULT_OK:
            raise MDRError(f"equalizer band read failed: {self.lib.result(r)}")
        return [int(v) for v in list(buf)[: count.value]]

    # 5 bands run -10..+10; the 10-band variant runs -6..+6. The library
    # rejects anything else, and rejects a count that is not 5 or 10.
    BAND_LIMITS = {5: 10, 10: 6}

    def set_equalizer_bands(self, values, settle=None):
        values = [int(v) for v in values]
        limit = self.BAND_LIMITS.get(len(values))
        if limit is None:
            raise ValueError("the device takes exactly 5 or 10 bands")
        if any(abs(v) > limit for v in values):
            raise ValueError(f"{len(values)} bands run from -{limit} to +{limit}")
        buf = (C.c_int8 * len(values))(*values)
        r = self.lib.set_eq_bands(self._hp, buf, len(values))
        if r != RESULT_OK:
            raise MDRError(f"equalizer band write failed: {self.lib.result(r)}")
        self.lib.hp_commit(self._hp)
        deadline = time.monotonic() + (self.write_settle if settle is None else settle)
        while time.monotonic() < deadline:
            self.pump(20)
        return list(values)

    # ---- connection, power, listening ----------------------------------

    def get_connection_mode(self):
        cm = ConnectionMode()
        r = self.lib.get_conn_mode(self._hp, C.byref(cm))
        if r != RESULT_OK:
            raise MDRError(f"connection mode read failed: {self.lib.result(r)}")
        return cm

    def set_audio_priority(self, priority, settle=None):
        """'quality' asks for LDAC's higher bitrate, 'stability' drops it."""
        if isinstance(priority, str):
            if priority not in AUDIO_PRIORITY_BY_NAME:
                raise ValueError(f"priority must be one of {sorted(AUDIO_PRIORITY_BY_NAME)}")
            priority = AUDIO_PRIORITY_BY_NAME[priority]
        cm = ConnectionMode(audio_priority=priority)
        r = self.lib.set_conn_mode(self._hp, C.byref(cm))
        if r != RESULT_OK:
            raise MDRError(f"connection mode write failed: {self.lib.result(r)}")
        self.lib.hp_commit(self._hp)
        deadline = time.monotonic() + (self.write_settle if settle is None else settle)
        while time.monotonic() < deadline:
            self.pump(20)
        return cm

    def get_power(self):
        pw = Power()
        r = self.lib.get_power(self._hp, C.byref(pw))
        if r != RESULT_OK:
            raise MDRError(f"power read failed: {self.lib.result(r)}")
        return pw

    def set_power(self, pw, settle=None):
        r = self.lib.set_power(self._hp, C.byref(pw))
        if r != RESULT_OK:
            raise MDRError(f"power write failed: {self.lib.result(r)}")
        self.lib.hp_commit(self._hp)
        deadline = time.monotonic() + (self.write_settle if settle is None else settle)
        while time.monotonic() < deadline:
            self.pump(20)
        return pw

    def shutdown(self, settle=0.6):
        """Ask the headphones to switch off.

        The settle is not optional here. Every other write can leave the frame
        for the session's own loop to flush, but this one is followed by
        tearing the session down, so with no pumping the command never leaves
        the machine -- which is exactly how "switch off" came to do nothing.
        """
        pw = self.get_power()
        pw.shutdown_requested = 1
        return self.set_power(pw, settle=settle)

    def get_listening(self):
        ls = Listening()
        r = self.lib.get_listening(self._hp, C.byref(ls))
        if r != RESULT_OK:
            raise MDRError(f"listening read failed: {self.lib.result(r)}")
        return ls

    def set_listening_mode(self, mode, room=None, settle=None):
        if isinstance(mode, str):
            if mode not in LISTENING_MODE_BY_NAME:
                raise ValueError(f"mode must be one of {sorted(LISTENING_MODE_BY_NAME)}")
            mode = LISTENING_MODE_BY_NAME[mode]
        ls = self.get_listening()
        ls.mode = mode
        if room is not None:
            if isinstance(room, str):
                room = ROOM_SIZE_BY_NAME[room]
            ls.background_room = room
        r = self.lib.set_listening(self._hp, C.byref(ls))
        if r != RESULT_OK:
            raise MDRError(f"listening write failed: {self.lib.result(r)}")
        self.lib.hp_commit(self._hp)
        deadline = time.monotonic() + (self.write_settle if settle is None else settle)
        while time.monotonic() < deadline:
            self.pump(20)
        return ls

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


def describe_noise(nc):
    parts = [f"mode: {NOISE_MODE.get(nc.mode, nc.mode)}"]
    if nc.mode == 2:
        parts.append(f"ambient level {nc.ambient_level}/{AMBIENT_LEVEL_MAX}")
        parts.append(f"focus on voice: {'yes' if nc.focus_on_voice else 'no'}")
    parts.append(f"button: {NOISE_BUTTON.get(nc.button_mode, nc.button_mode)}")
    if nc.adaptive_ambient:
        parts.append(f"adaptive ({ADAPTIVE_SENSITIVITY.get(nc.adaptive_sensitivity)})")
    return ", ".join(parts)


def describe_equalizer(eq, bands=None):
    parts = [f"preset: {EQ_PRESET.get(eq.preset, eq.preset)}"]
    parts.append(f"clear bass: {eq.clear_bass:+d}")
    if bands:
        parts.append("bands: " + " ".join(f"{v:+d}" for v in bands))
    parts.append(f"DSEE: {'on' if eq.dsee_enabled else 'off'}"
                 + (f" ({DSEE.get(eq.dsee_type)})" if eq.dsee_enabled else ""))
    return ", ".join(parts)


def describe_power(pw):
    off = pw.auto_power_off_minutes
    parts = [f"auto power off: {'never' if off == 0 else str(off) + ' min'}"]
    parts.append(f"when removed: {WEARING_POWER.get(pw.wearing_power, pw.wearing_power)}")
    parts.append(f"auto pause: {'yes' if pw.auto_pause else 'no'}")
    if pw.head_gesture:
        parts.append("head gesture: yes")
    return ", ".join(parts)


def describe_listening(ls):
    mode = LISTENING_MODE.get(ls.mode, ls.mode)
    if ls.mode == 1:
        return f"mode: {mode}, room: {ROOM_SIZE.get(ls.background_room, ls.background_room)}"
    return f"mode: {mode}"
