"""Tests: build a synthetic Windows SYSTEM hive + BlueZ directory and run the tool on them.

Run with:  python3 -m unittest discover -s tests
"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import struct
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("btsync", os.path.join(HERE, "..", "bt-dualboot-sync"))
_spec = importlib.util.spec_from_loader("btsync", _loader)
bt = importlib.util.module_from_spec(_spec)
sys.modules["btsync"] = bt  # dataclasses needs the module registered (Python < 3.13)
_loader.exec_module(bt)


# ---------------------------------------------------------------- tiny hive writer
class HiveBuilder:
    def __init__(self):
        self.buf = bytearray(b"hbin" + b"\0" * 28)

    def cell(self, payload: bytes) -> int:
        off = len(self.buf)
        size = (len(payload) + 4 + 7) // 8 * 8
        self.buf += struct.pack("<i", -size) + payload + b"\0" * (size - 4 - len(payload))
        return off

    def value(self, name: str, vtype: int, data: bytes) -> int:
        if len(data) <= 4:
            doff, dsize = int.from_bytes(data.ljust(4, b"\0"), "little"), len(data) | 0x80000000
        else:
            doff, dsize = self.cell(data), len(data)
        nb = name.encode("latin-1")
        return self.cell(b"vk" + struct.pack("<HIIIHH", len(nb), dsize, doff, vtype, 1, 0) + nb)

    def key(self, name: str, subkeys=(), values=()) -> int:
        subkeys, values = list(subkeys), list(values)
        sl = self.cell(b"lf" + struct.pack("<H", len(subkeys)) +
                       b"".join(struct.pack("<II", o, 0) for o in subkeys)) if subkeys else 0xFFFFFFFF
        vl = self.cell(b"".join(struct.pack("<I", o) for o in values)) if values else 0xFFFFFFFF
        nb = name.encode("latin-1")
        body = (b"nk" + struct.pack("<H", 0x20) + b"\0" * 8 +
                struct.pack("<15I", 0, 0, len(subkeys), 0, sl, 0xFFFFFFFF, len(values), vl,
                            0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0, 0) +
                struct.pack("<HH", len(nb), 0) + nb)
        return self.cell(body)

    def build(self, tree, dirty=False) -> bytes:
        """tree: (name, {value_name: (type, bytes)}, [children])"""
        def mk(node):
            name, vals, children = node
            kids = [mk(c) for c in children]
            voffs = [self.value(n, t, d) for n, (t, d) in vals.items()]
            return self.key(name, kids, voffs)
        root = mk(tree)
        hbin_size = (len(self.buf) + 4095) // 4096 * 4096
        self.buf += b"\0" * (hbin_size - len(self.buf))
        struct.pack_into("<II", self.buf, 4, 0, hbin_size)
        header = bytearray(4096)
        header[:4] = b"regf"
        struct.pack_into("<II", header, 4, 5, 6 if dirty else 5)
        struct.pack_into("<I", header, 0x24, root)
        return bytes(header + self.buf)


BIN, DWORD, QWORD = bt.REG_BINARY, bt.REG_DWORD, bt.REG_QWORD
ADAPTER = "001a7dda7113"
HEADSET = "a1b2c3d4e5f6"      # classic
MOUSE_WIN = "c0ffee000002"    # LE, address in Windows
MOUSE_LNX = "C0:FF:EE:00:00:01"  # same mouse, older address in Linux
KB = "d00d00d00d01"           # LE keyboard, same address both sides

HEADSET_KEY = bytes(range(16))
MOUSE_LTK = bytes(range(16, 32))
MOUSE_IRK = bytes(range(32, 48))
KB_LTK = bytes(range(48, 64))


def make_hive(headset_key=HEADSET_KEY, kb_ltk=KB_LTK, dirty=False) -> bytes:
    def le(ltk, irk=None, ediv=0x1234, erand=0xFEDCBA9876543210):
        v = {"LTK": (BIN, ltk), "KeyLength": (DWORD, struct.pack("<I", 16)),
             "EDIV": (DWORD, struct.pack("<I", ediv)), "ERand": (QWORD, struct.pack("<Q", erand))}
        if irk:
            v["IRK"] = (BIN, irk)
        return v
    keys = ("Keys", {}, [(ADAPTER, {HEADSET: (BIN, headset_key), "CentralIRK": (BIN, b"\1" * 16)},
                          [(MOUSE_WIN, le(MOUSE_LTK, MOUSE_IRK), []), (KB, le(kb_ltk), [])])])
    devices = ("Devices", {}, [
        (HEADSET, {"Name": (BIN, b"My Headset\0")}, []),
        (MOUSE_WIN, {"Name": (BIN, b"MX Mouse\0")}, []),
        (KB, {"Name": (BIN, b"Keyboard K1\0")}, []),
    ])
    tree = ("ROOT", {}, [
        ("Select", {"Current": (DWORD, struct.pack("<I", 1))}, []),
        ("ControlSet001", {}, [("Services", {}, [("BTHPORT", {}, [("Parameters", {}, [keys, devices])])])]),
    ])
    return HiveBuilder().build(tree, dirty)


def mac(w):
    return bt.win_to_mac(w)


class SyncTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.hive = os.path.join(self.tmp, "SYSTEM")
        self.bluez = os.path.join(self.tmp, "bluetooth")
        self.state = os.path.join(self.tmp, "state", "state.json")
        self.export = os.path.join(self.tmp, "esp", "bt-dualboot-sync", "bluez-keys.json")
        self.write_hive()
        ad = os.path.join(self.bluez, mac(ADAPTER))
        self.devs = {}
        for m, body in [
            (mac(HEADSET), "[General]\nName=My Headset\nClass=0x240404\n\n[LinkKey]\nKey=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF\nType=4\nPINLength=0\n"),
            (MOUSE_LNX, "[General]\nName=MX Mouse\nAddressType=static\n\n[LongTermKey]\nKey=00000000000000000000000000000000\nAuthenticated=0\nEncSize=16\nEDiv=1\nRand=2\n"),
            (mac(KB), "[General]\nName=Keyboard K1\n\n[LongTermKey]\nKey=%s\nAuthenticated=0\nEncSize=16\nEDiv=%d\nRand=%d\n"
             % (KB_LTK.hex().upper(), 0x1234, 0xFEDCBA9876543210)),
        ]:
            os.makedirs(os.path.join(ad, m))
            with open(os.path.join(ad, m, "info"), "w") as f:
                f.write(body)
            self.devs[m] = os.path.join(ad, m, "info")
        os.makedirs(os.path.join(ad, "cache"))
        with open(os.path.join(ad, "cache", MOUSE_LNX), "w") as f:
            f.write("[General]\nName=MX Mouse\n")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_hive(self, **kw):
        with open(self.hive, "wb") as f:
            f.write(make_hive(**kw))

    def run_tool(self, *args):
        return bt.main(list(args) + ["--windows", self.hive, "--bluez-dir", self.bluez,
                                     "--state-file", self.state, "--backup-dir",
                                     os.path.join(self.tmp, "backup"), "--export-path", self.export,
                                     "--yes", "--no-restart", "-q"])

    def info(self, m):
        cp = bt.new_info_parser()
        cp.read(os.path.join(self.bluez, mac(ADAPTER), m, "info"))
        return cp

    # ------------------------------------------------------------------
    def test_parse_hive(self):
        entries = bt.read_windows_keys(bt.Hive.open(self.hive))
        by = {(e.mac, e.kind): e for e in entries}
        self.assertEqual(len(entries), 3)  # CentralIRK must be ignored
        hs = by[(mac(HEADSET), "classic")]
        self.assertEqual(hs.link_key, HEADSET_KEY)
        self.assertEqual(hs.name, "My Headset")
        ms = by[(mac(MOUSE_WIN), "le")]
        self.assertEqual((ms.ltk, ms.irk, ms.ediv, ms.erand, ms.key_length),
                         (MOUSE_LTK, MOUSE_IRK, 0x1234, 0xFEDCBA9876543210, 16))

    def test_sync_windows_to_linux(self):
        self.assertEqual(self.run_tool("sync"), 0)
        hs = self.info(mac(HEADSET))
        self.assertEqual(hs.get("LinkKey", "Key"), HEADSET_KEY.hex().upper())
        self.assertEqual(hs.get("General", "Class"), "0x240404")  # other data preserved
        # mouse moved to its new address, keys updated, IRK byte-reversed
        self.assertFalse(os.path.exists(os.path.join(self.bluez, mac(ADAPTER), MOUSE_LNX)))
        ms = self.info(mac(MOUSE_WIN))
        self.assertEqual(ms.get("LongTermKey", "Key"), MOUSE_LTK.hex().upper())
        self.assertEqual(ms.get("LongTermKey", "EDiv"), str(0x1234))
        self.assertEqual(ms.get("LongTermKey", "Rand"), str(0xFEDCBA9876543210))
        self.assertEqual(ms.get("IdentityResolvingKey", "Key"), MOUSE_IRK[::-1].hex().upper())
        self.assertTrue(os.path.exists(os.path.join(self.bluez, mac(ADAPTER), "cache", mac(MOUSE_WIN))))
        # backup taken
        self.assertEqual(len(os.listdir(os.path.join(self.tmp, "backup"))), 1)

    def test_dry_run_changes_nothing(self):
        before = open(self.devs[mac(HEADSET)]).read()
        self.assertEqual(self.run_tool("sync", "--dry-run"), 0)
        self.assertEqual(open(self.devs[mac(HEADSET)]).read(), before)

    def test_history_protects_newer_linux_pairing(self):
        self.run_tool("sync")
        # user re-pairs the headset in Linux -> new Linux key, Windows unchanged
        cp = self.info(mac(HEADSET))
        cp.set("LinkKey", "Key", "AB" * 16)
        bt.write_info(cp, self.devs[mac(HEADSET)])
        self.run_tool("sync")
        self.assertEqual(self.info(mac(HEADSET)).get("LinkKey", "Key"), "AB" * 16)  # not overwritten
        # export sends it to Windows
        self.assertEqual(self.run_tool("export"), 0)
        doc = json.load(open(self.export))
        self.assertEqual([(d["mac"], d["link_key"]) for d in doc["devices"]], [(HEADSET, "AB" * 16)])

    def test_windows_repair_detected_after_history(self):
        self.run_tool("sync")
        self.write_hive(headset_key=b"\x42" * 16)  # re-paired in Windows
        self.run_tool("auto")
        self.assertEqual(self.info(mac(HEADSET)).get("LinkKey", "Key"), "42" * 16)
        self.assertFalse(os.path.exists(self.export))

    def test_auto_exports_le_and_cleans_up(self):
        self.run_tool("auto")
        cp = self.info(mac(KB))
        cp.set("LongTermKey", "Key", "CD" * 16)
        cp.set("LongTermKey", "Rand", "1")
        bt.write_info(cp, os.path.join(self.bluez, mac(ADAPTER), mac(KB), "info"))
        self.run_tool("auto")
        doc = json.load(open(self.export))
        self.assertEqual(len(doc["devices"]), 1)
        d = doc["devices"][0]
        self.assertEqual((d["kind"], d["mac"], d["ltk"], d["erand"]), ("le", KB, "CD" * 16, "%016x" % 1))
        # Windows imported it -> both sides equal -> export file removed on next boot
        self.write_hive(kb_ltk=bytes.fromhex("CD" * 16))
        # (simulate Windows writing the same EDIV/ERand as Linux)
        cp.set("LongTermKey", "EDiv", str(0x1234))
        cp.set("LongTermKey", "Rand", str(0xFEDCBA9876543210))
        bt.write_info(cp, os.path.join(self.bluez, mac(ADAPTER), mac(KB), "info"))
        self.run_tool("auto")
        self.assertFalse(os.path.exists(self.export))

    def test_dirty_hive_flag(self):
        self.write_hive(dirty=True)
        self.assertTrue(bt.Hive.open(self.hive).dirty)

    def test_rejects_non_hive(self):
        with open(self.hive, "wb") as f:
            f.write(b"x" * 5000)
        self.assertEqual(self.run_tool("status"), 1)


if __name__ == "__main__":
    unittest.main()
