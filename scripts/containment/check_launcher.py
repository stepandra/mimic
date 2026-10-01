#!/usr/bin/env python3
"""Packaging validation only; never execute or qualify a launcher on the host."""
import argparse
from pathlib import Path
import stat
import struct


def inspect(path):
    path = Path(path)
    if not path.is_absolute() or path.is_symlink():
        raise ValueError("absolute regular Linux launcher required")
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o111:
        raise ValueError("executable regular Linux launcher required")
    with path.open("rb") as source:
        header = source.read(64)
        if len(header) != 64 or header[:7] != b"\x7fELF\x02\x01\x01":
            raise ValueError("ELF64 little-endian Linux launcher required")
        kind, machine, version = struct.unpack_from("<HHI", header, 16)
        phoff = struct.unpack_from("<Q", header, 32)[0]
        phsize, count = struct.unpack_from("<HH", header, 54)
        if kind not in (2, 3) or machine not in (62, 183) or version != 1:
            raise ValueError("unsupported Linux launcher architecture")
        if phsize != 56 or not 1 <= count <= 128 or phoff < 64:
            raise ValueError("invalid ELF program headers")
        if phoff + phsize * count > info.st_size:
            raise ValueError("truncated ELF program headers")
        source.seek(phoff)
        for _ in range(count):
            program = source.read(phsize)
            if len(program) != phsize:
                raise ValueError("truncated ELF program headers")
            if struct.unpack_from("<I", program)[0] == 3:
                raise ValueError("launcher must be static (no ELF interpreter)")
    return "x86_64" if machine == 62 else "aarch64"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    try:
        print(inspect(args.path))
    except (OSError, ValueError) as error:
        parser.exit(2, f"blocked: {error}\n")
