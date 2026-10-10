"""Verify native backend payloads and optional Discord SDKs in release APKs."""

import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

import check_backend_apk as checker


class BackendApkAuditTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.apk = Path(directory.name) / "release.apk"
        self.entries = {"classes.dex": b"backend classes"}
        for abi, (elf_class, machine) in checker.ABI_LAYOUT.items():
            header = bytearray(20)
            header[:6] = b"\x7fELF" + bytes([elf_class, 1])
            struct.pack_into("<H", header, 18, machine)
            for library in checker.CORE_LIBRARIES + (
                "libspotiflac_mobile.so", "libjnidispatch.so",
            ):
                self.entries[f"lib/{abi}/{library}"] = bytes(header)

    def audit(self, abis=("arm64-v8a", "armeabi-v7a"), discord_sdk=False):
        with zipfile.ZipFile(self.apk, "w") as zf:
            for name, data in self.entries.items():
                zf.writestr(name, data)
        return checker.audit(self.apk, "rust", abis, discord_sdk)

    def test_universal_passes(self):
        self.assertEqual(len(self.audit()), 64)

    def test_split_apks_pass(self):
        original = self.entries.copy()
        for abi in checker.ABI_LAYOUT:
            self.entries = {name: data for name, data in original.items()
                            if not name.startswith("lib/") or name.startswith(f"lib/{abi}/")}
            self.assertEqual(len(self.audit((abi,))), 64)

    def test_missing_backend_in_either_abi_fails(self):
        for abi in checker.ABI_LAYOUT:
            for library in ("libspotiflac_mobile.so", "libjnidispatch.so"):
                with self.subTest(abi=abi, library=library):
                    path = f"lib/{abi}/{library}"
                    data = self.entries.pop(path)
                    with self.assertRaisesRegex(checker.AuditError, "missing APK entry"):
                        self.audit()
                    self.entries[path] = data

    def test_wrong_architecture_fails(self):
        self.entries["lib/armeabi-v7a/libspotiflac_mobile.so"] = self.entries[
            "lib/arm64-v8a/libspotiflac_mobile.so"
        ]
        with self.assertRaisesRegex(checker.AuditError, "ELF class"):
            self.audit()

    def test_disabled_sdk_cannot_leak_from_build_cache(self):
        for abi in checker.ABI_LAYOUT:
            path = f"lib/{abi}/libdiscord_partner_sdk.so"
            self.entries[path] = self.entries[f"lib/{abi}/libapp.so"]
            with self.assertRaisesRegex(checker.AuditError, "unexpectedly contains Discord"):
                self.audit()
            del self.entries[path]

    def test_enabled_sdk_requires_both_libraries_for_each_abi(self):
        for abi in checker.ABI_LAYOUT:
            for library in checker.DISCORD_LIBRARIES:
                self.entries[f"lib/{abi}/{library}"] = self.entries[f"lib/{abi}/libapp.so"]
        self.assertEqual(len(self.audit(discord_sdk=True)), 64)
        del self.entries["lib/armeabi-v7a/libdiscord_partner_sdk.so"]
        with self.assertRaisesRegex(checker.AuditError, "missing APK entry"):
            self.audit(discord_sdk=True)


if __name__ == "__main__":
    unittest.main()
