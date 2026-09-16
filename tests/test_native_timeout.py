"""Optional libmdr integration test with a silent transport, no Bluetooth.

Run with MDR_TEST_BUILD=/path/to/cmake/build (or /usr/lib/mdrctl).
"""
import ctypes as C
import os
from pathlib import Path
import sys
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "daemon/lib"))
import mdr


@unittest.skipUnless(os.environ.get("MDR_TEST_BUILD"), "set MDR_TEST_BUILD for native transport tests")
class NativeTimeoutTest(unittest.TestCase):
    def test_missing_ack_retries_while_caller_sleeps(self):
        lib = mdr.Library(os.environ["MDR_TEST_BUILD"])
        io = C.CFUNCTYPE(C.c_uint32, C.c_void_p, C.c_void_p, C.c_int, C.POINTER(C.c_int))
        poll_type = C.CFUNCTYPE(C.c_uint32, C.c_void_p, C.c_int)
        sent = []

        @io
        def send(_user, data, size, count):
            sent.append(time.monotonic())
            count[0] = size
            return mdr.RESULT_OK

        @io
        def recv(_user, data, size, count):
            count[0] = 0
            return mdr.RESULT_INPROGRESS

        @poll_type
        def poll(_user, timeout):
            return mdr.RESULT_OK

        # MDRConnection from mdr-c/Connection.h. Only poll/send/recv are used.
        class Connection(C.Structure):
            _fields_ = [(name, C.c_void_p) for name in (
                "user", "connect", "disconnect", "recv", "send", "poll",
                "getDevicesList", "freeDevicesList", "getLastError",
            )]

        conn = Connection(recv=C.cast(recv, C.c_void_p),
                          send=C.cast(send, C.c_void_p),
                          poll=C.cast(poll, C.c_void_p))
        hp = C.c_void_p()
        self.assertEqual(lib.hp_create(mdr.ABI_VERSION, C.byref(conn), mdr.PROTOCOL_V2, C.byref(hp)), 0)
        try:
            lib.hp_init(hp)
            event = C.c_uint32()
            deadline = time.monotonic() + 2.5
            while len(sent) < 2 and time.monotonic() < deadline:
                lib.hp_poll(hp, C.byref(event))
                time.sleep(0.02)  # same idle cadence as mdrctld
            self.assertGreaterEqual(len(sent), 2, "ACK retry must use elapsed time, not consumed CPU time")
        finally:
            lib.hp_destroy(hp)
