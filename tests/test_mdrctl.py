#!/usr/bin/env python3
"""Tests for the parts that were wrong once and could be wrong again.

Everything here runs without headphones, without BlueZ and without libmdr.
That is deliberate: the bugs worth catching were not hardware problems. They
were an argument staged in the wrong order, a value quietly restated, and a
reading mistaken for someone turning a dial on the headset -- all of which are
pure logic, and none of which were visible in the panel.

    python3 -m unittest discover -s tests -v
"""
import ctypes
import importlib.util
import json
import os
import sys
import time
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "lib"))
import mdr  # noqa: E402


def load_daemon():
    """Import bin/mdrctld, which has no .py on the end of it."""
    spec = importlib.util.spec_from_loader(
        "mdrctld",
        importlib.machinery.SourceFileLoader("mdrctld", os.path.join(ROOT, "bin", "mdrctld")),
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mdrctld = load_daemon()


class RecordingLib:
    """Stands in for libmdr and writes down the order it was called in."""

    def __init__(self):
        self.calls = []

    def _record(self, name, result=mdr.RESULT_OK):
        def call(*args):
            self.calls.append(name)
            return result
        return call

    def __getattr__(self, name):
        return self._record(name)

    def result(self, code):
        return f"result-{code}"

    def names(self):
        return [c for c in self.calls]


class EqualizerWriteTest(unittest.TestCase):
    """The equaliser bug that took a frame decoder to find.

    Bands and clear bass share one message on the wire. Committing between the
    two stages flushed it early, carrying the *old* bands -- indistinguishable,
    from the outside, from the headset ignoring the write.
    """

    def headphones(self, bands=(0, 0, 0, 0, 0), clear_bass=0):
        hp = mdr.Headphones.__new__(mdr.Headphones)
        hp.lib = RecordingLib()
        hp._hp = ctypes.c_void_p(1)
        hp.write_settle = 0.0

        eq = mdr.Equalizer()
        eq.clear_bass = clear_bass
        hp._eq_for_write = lambda: eq
        hp.get_equalizer_bands = lambda: list(bands)
        hp.pump = lambda *a, **k: None
        hp._eq = eq
        return hp

    def test_stages_both_halves_before_committing(self):
        hp = self.headphones()
        hp.write_eq(bands=[1, 2, 3, 4, 5], clear_bass=4)

        calls = hp.lib.names()
        self.assertEqual(
            calls,
            ["set_eq", "set_eq_bands", "hp_commit"],
            "bands and clear bass must both be staged before the single commit; "
            "a commit in between sends a frame carrying the old bands",
        )

    def test_commits_exactly_once(self):
        hp = self.headphones()
        hp.write_eq(bands=[1, 2, 3, 4, 5], clear_bass=4)
        self.assertEqual(hp.lib.names().count("hp_commit"), 1)

    def test_clear_bass_alone_still_sends_the_bands(self):
        """A clear-bass-only change is dropped unless bands go with it, so the
        current bands are read back and restated."""
        hp = self.headphones(bands=(2, 5, 7, 7, 9))
        values = hp.write_eq(clear_bass=-3)

        self.assertEqual(values, [2, 5, 7, 7, 9])
        self.assertIn("set_eq_bands", hp.lib.names())
        self.assertEqual(hp._eq.clear_bass, -3)

    def test_bands_alone_leaves_clear_bass_where_it_was(self):
        """The other half of the same message: a bands write carries whatever
        clear bass is staged, which is how it used to drift a step per edit."""
        hp = self.headphones(clear_bass=4)
        hp.write_eq(bands=[0, 0, 0, 0, 0])
        self.assertEqual(hp._eq.clear_bass, 4)

    def test_rejects_a_band_count_the_device_does_not_take(self):
        hp = self.headphones()
        with self.assertRaises(ValueError):
            hp.write_eq(bands=[1, 2, 3])
        self.assertEqual(hp.lib.names(), [], "nothing should reach the device")

    def test_rejects_out_of_range_values(self):
        hp = self.headphones()
        with self.assertRaises(ValueError):
            hp.write_eq(bands=[99, 0, 0, 0, 0])
        with self.assertRaises(ValueError):
            hp.write_eq(bands=[0, 0, 0, 0, 0], clear_bass=99)


BUSCTL = {
    "data": [{
        "/org/bluez/hci0/dev_AC_80_0A_CE_86_C1": {
            "org.bluez.Device1": {
                "Address": {"type": "s", "data": "00:00:5E:00:53:01"},
                "Name": {"type": "s", "data": "WH-1000XM5"},
                "Connected": {"type": "b", "data": True},
                "UUIDs": {"type": "as", "data": [
                    "0000110b-0000-1000-8000-00805f9b34fb",
                    "956C7B26-D49A-4BA8-B03F-B17D393CB6E2",
                ]},
            }
        },
        "/org/bluez/hci0/dev_6C_93_08_61_93_EF": {
            "org.bluez.Device1": {
                "Address": {"type": "s", "data": "00:00:5E:00:53:03"},
                "Name": {"type": "s", "data": "A Keyboard"},
                "Connected": {"type": "b", "data": True},
                "UUIDs": {"type": "as", "data": ["00001124-0000-1000-8000-00805f9b34fb"]},
            }
        },
        "/org/bluez/hci0/dev_AC_80_0A_CE_86_C2": {
            "org.bluez.Device1": {
                "Address": {"type": "s", "data": "00:00:5E:00:53:02"},
                "Name": {"type": "s", "data": "WF-1000XM5"},
                "Connected": {"type": "b", "data": False},
                "UUIDs": {"type": "as", "data": ["956c7b26-d49a-4ba8-b03f-b17d393cb6e2"]},
            }
        },
    }]
}


def fake_busctl(payload=BUSCTL, returncode=0):
    result = mock.Mock(returncode=returncode, stdout=json.dumps(payload))
    return mock.patch.object(mdrctld.subprocess, "run", return_value=result)


class DiscoveryTest(unittest.TestCase):
    """Finding the headphones by what they can do rather than by address, so a
    pair the daemon has never seen works the moment it is connected."""

    def test_picks_the_connected_device_that_speaks_mdr(self):
        with fake_busctl():
            path, dev = mdrctld.find_headphones()
        self.assertEqual(dev["mac"], "00:00:5E:00:53:01")
        self.assertEqual(dev["name"], "WH-1000XM5")
        self.assertTrue(path.endswith("dev_AC_80_0A_CE_86_C1"))

    def test_ignores_a_connected_device_that_does_not(self):
        with fake_busctl():
            _, dev = mdrctld.find_headphones()
        self.assertNotEqual(dev["mac"], "00:00:5E:00:53:03")

    def test_ignores_an_mdr_device_that_is_not_connected(self):
        """The buds are paired but in their case; they are not the answer."""
        with fake_busctl():
            _, dev = mdrctld.find_headphones()
        self.assertNotEqual(dev["mac"], "00:00:5E:00:53:02")

    def test_uuid_match_is_case_insensitive(self):
        """BlueZ returns them lowercase; the XM5 entry here is uppercase."""
        with fake_busctl():
            _, dev = mdrctld.find_headphones()
        self.assertIsNotNone(dev)

    def test_a_pin_narrows_it_to_one_device(self):
        with fake_busctl():
            _, dev = mdrctld.find_headphones("00:00:5E:00:53:02")
        self.assertIsNone(dev, "the pinned pair is not connected, so nothing matches")

    def test_nothing_connected_is_not_an_error(self):
        empty = {"data": [{}]}
        with fake_busctl(empty):
            path, dev = mdrctld.find_headphones()
        self.assertIsNone(path)
        self.assertIsNone(dev)

    def test_survives_busctl_failing(self):
        with fake_busctl(returncode=1):
            self.assertEqual(mdrctld.bluez_devices(), {})

    def test_survives_busctl_returning_nonsense(self):
        result = mock.Mock(returncode=0, stdout="not json")
        with mock.patch.object(mdrctld.subprocess, "run", return_value=result):
            self.assertEqual(mdrctld.bluez_devices(), {})


class ClaimTest(unittest.TestCase):
    """Whose change is this? The headset does not echo our own writes back, so
    the panel shows what we asked for until its reading moves. Getting this
    wrong makes sliders jump to old values under your hand."""

    def setUp(self):
        self.d = mdrctld.Daemon.__new__(mdrctld.Daemon)
        self.d.claims = {}
        self.d.recent = {}
        self.d.state = {}
        self.d.acks = 0
        self.d.retransmits = 0

    def test_shows_what_we_asked_for_until_the_device_agrees(self):
        self.d.state = {"mode": "off"}
        self.d.claim("mode", "ambient")
        out = self.d.apply_claims({"mode": "off"})
        self.assertEqual(out["mode"], "ambient")
        self.assertEqual(out["unconfirmed"], ["mode"])

    def test_stops_overriding_once_the_device_agrees(self):
        self.d.state = {"mode": "off"}
        self.d.claim("mode", "ambient")
        out = self.d.apply_claims({"mode": "ambient"})
        self.assertEqual(out["unconfirmed"], [])
        self.assertNotIn("mode", self.d.claims)

    def test_a_change_made_on_the_headset_wins(self):
        self.d.state = {"mode": "off"}
        self.d.claim("mode", "ambient")
        out = self.d.apply_claims({"mode": "cancelling"})
        self.assertEqual(out["mode"], "cancelling", "the button on the headset was pressed")
        self.assertNotIn("mode", self.d.claims)

    def test_a_late_echo_of_our_own_write_is_not_a_change(self):
        """The device echoes a write back a moment later, often after the next
        write has gone out. Treating that as someone turning a dial is what
        made the sliders jump."""
        self.d.state = {"ambient_level": 5}
        self.d.claim("ambient_level", 10)
        self.d.claim("ambient_level", 15)
        out = self.d.apply_claims({"ambient_level": 10})   # the echo of the first
        self.assertEqual(out["ambient_level"], 15, "keep the newer value we asked for")
        self.assertIn("ambient_level", self.d.claims)

    def test_a_claim_that_is_never_confirmed_expires(self):
        self.d.state = {"dsee": False}
        self.d.claim("dsee", True)
        value, baseline, _, acks = self.d.claims["dsee"]
        stale = time.monotonic() - (mdrctld.Daemon.CLAIM_TTL + 1)
        self.d.claims["dsee"] = (value, baseline, stale, acks)
        out = self.d.apply_claims({"dsee": False})
        self.assertEqual(out["dsee"], False, "stop lying about it eventually")
        self.assertEqual(self.d.claims, {})

    def test_silence_from_the_device_is_reported(self):
        self.d.state = {"mode": "off"}
        self.d.claim("mode", "ambient")
        value, baseline, _, acks = self.d.claims["mode"]
        self.d.claims["mode"] = (value, baseline, time.monotonic() - 2, acks)
        out = self.d.apply_claims({"mode": "off"})
        self.assertEqual(out["unacknowledged"], ["mode"],
                         "the protocol acknowledges every command, so silence is a failure")

    def test_an_acknowledged_command_is_not_reported_as_silent(self):
        self.d.state = {"mode": "off"}
        self.d.claim("mode", "ambient")
        self.d.acks += 1
        value, baseline, _, acks = self.d.claims["mode"]
        self.d.claims["mode"] = (value, baseline, time.monotonic() - 2, acks)
        out = self.d.apply_claims({"mode": "off"})
        self.assertEqual(out["unacknowledged"], [])


class BatteryTest(unittest.TestCase):
    """One number has to stand for a device with three batteries."""

    def test_a_headset_has_only_one_battery_to_pick(self):
        picked = mdrctld.headline_battery([{"part": "main", "level": 57, "charging": "no"}])
        self.assertEqual(picked["level"], 57)

    def test_earbuds_report_the_emptier_of_the_two_being_worn(self):
        picked = mdrctld.headline_battery([
            {"part": "left", "level": 100, "charging": "no"},
            {"part": "right", "level": 40, "charging": "no"},
            {"part": "case", "level": 71, "charging": "no"},
        ])
        self.assertEqual(picked["level"], 40,
                         "the right bud is what ends the listening, not the left")

    def test_the_case_never_stands_for_the_buds(self):
        """It is charged and sitting in a pocket; it says nothing about how
        long the music lasts."""
        picked = mdrctld.headline_battery([
            {"part": "left", "level": 80, "charging": "no"},
            {"part": "right", "level": 80, "charging": "no"},
            {"part": "case", "level": 5, "charging": "no"},
        ])
        self.assertEqual(picked["level"], 80)

    def test_a_case_on_its_own_is_not_a_reading(self):
        self.assertIsNone(mdrctld.headline_battery([{"part": "case", "level": 71}]))

    def test_nothing_reported_is_not_an_error(self):
        self.assertIsNone(mdrctld.headline_battery([]))


class ExplainTest(unittest.TestCase):
    """The transport says EBUSY; the user needs to know the headset only has
    one control channel and something else is holding it."""

    def test_busy_and_timeout_say_the_same_thing(self):
        busy = mdrctld.Daemon.explain("Device or resource busy")
        timeout = mdrctld.Daemon.explain("Connection timed out")
        self.assertEqual(busy, timeout)
        self.assertIn("one at a time", busy)

    def test_does_not_blame_anything_it_cannot_know(self):
        """It used to name Sony's phone app. A screenshot disproved that."""
        message = mdrctld.Daemon.explain("Device or resource busy")
        self.assertNotIn("Sony", message)
        self.assertIn("may", message, "a possibility, not an accusation")

    def test_an_unknown_error_is_passed_through_untouched(self):
        self.assertEqual(mdrctld.Daemon.explain("no such adapter"), "no such adapter")


if __name__ == "__main__":
    unittest.main()
