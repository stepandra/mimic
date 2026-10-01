"""Synthetic ELF fixtures only; no executable or sandbox is launched."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("check_launcher", Path(__file__).with_name("check_launcher.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class LauncherArtifactTests(unittest.TestCase):
    def binary(self, root, machine=183, program_type=1):
        path = Path(root) / "synthetic-launch"
        header = bytearray(64)
        header[:7] = b"\x7fELF\x02\x01\x01"
        struct.pack_into("<HHI", header, 16, 2, machine, 1)
        struct.pack_into("<Q", header, 32, 64)
        struct.pack_into("<HH", header, 54, 56, 1)
        program = bytearray(56)
        struct.pack_into("<I", program, 0, program_type)
        path.write_bytes(header + program)
        path.chmod(0o700)
        return path

    def test_supported_static_architectures(self):
        with tempfile.TemporaryDirectory() as root:
            for machine, expected in ((62, "x86_64"), (183, "aarch64")):
                self.assertEqual(check.inspect(self.binary(root, machine)), expected)

    def test_dynamic_or_unknown_machine_denied(self):
        with tempfile.TemporaryDirectory() as root:
            for machine, kind in ((183, 3), (3, 1)):
                with self.assertRaises(ValueError):
                    check.inspect(self.binary(root, machine, kind))

    def test_wrong_format_truncation_and_permissions_denied(self):
        with tempfile.TemporaryDirectory() as root:
            path = self.binary(root)
            path.chmod(0o600)
            with self.assertRaises(ValueError): check.inspect(path)
            path.chmod(0o700)
            data = path.read_bytes()
            for bad in (b"#!/bin/sh\n", data[:80], b"xxxx" + data[4:]):
                path.write_bytes(bad)
                with self.assertRaises(ValueError): check.inspect(path)

    def test_symlink_and_relative_denied(self):
        with tempfile.TemporaryDirectory() as root:
            path = self.binary(root)
            link = Path(root) / "link"
            link.symlink_to(path)
            with self.assertRaises(ValueError): check.inspect(link)
            with self.assertRaises(ValueError): check.inspect(Path("relative"))


if __name__ == "__main__":
    unittest.main()
