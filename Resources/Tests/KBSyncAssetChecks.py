#!/usr/bin/env python3
"""Offline regression checks for the Apple runtime asset parser using synthetic data."""
import bz2
import hashlib
import importlib.util
import io
from pathlib import Path
import struct
import tempfile
from unittest.mock import patch
import zlib

SCRIPT = Path(__file__).resolve().parents[1] / "Scripts/prepare.kbsync.assets.py"
module_spec = importlib.util.spec_from_file_location("kbsync_assets", SCRIPT)
assets = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(assets)


class ShortReads(io.BytesIO):
    def __init__(self, data, chunk):
        super().__init__(data)
        self.chunk = chunk

    def read(self, size=-1):
        return super().read(self.chunk if size < 0 else min(size, self.chunk))


def rejects(error, action):
    try:
        action()
    except error:
        return
    raise AssertionError("Expected " + error.__name__)


def bzip_checks():
    data = bytes(range(256)) * 300
    compressed = bz2.compress(data, compresslevel=9)[4:]
    # One compressed byte cannot produce output; an empty intermediate result is not EOF.
    for chunk, count in [(1, len(data)), (65536, 17)]:
        source = ShortReads(compressed, chunk)
        stream = assets.BZipStream(source)
        assert assets.exact(stream, count) == data[:count]
        assert stream.read(0) == b""
        assert assets.exact(stream, len(data) - count) == data[count:]
        assert stream.read(1) == stream.read(1) == b""
    source = ShortReads(compressed, 1)
    assert assets.BZipStream(source).read(0) == b"" and source.tell() == 0
    empty = assets.BZipStream(ShortReads(bz2.compress(b"")[4:], 1))
    assert empty.read(1) == b""
    rejects(EOFError, lambda: assets.exact(assets.BZipStream(ShortReads(compressed[:-1], 1)), len(data) + 1))
    rejects(EOFError, lambda: assets.BZipStream(io.BytesIO()).read(1))
    rejects(OSError, lambda: assets.BZipStream(io.BytesIO(b"invalid bzip data")).read(1))
    assert assets.exact(ShortReads(b"abc", 1), 3) == b"abc"
    rejects(EOFError, lambda: assets.exact(io.BytesIO(b"ab"), 3))


IMAGE = b"synthetic Apple runtime image"
IMAGE_PATH = "./System/Library/Fixture"
IMAGE_SPEC = (len(IMAGE), hashlib.sha256(IMAGE).hexdigest(), IMAGE_PATH)
TOC_XML = b"<xar><toc><file><name>Payload</name><data><offset>7</offset></data></file></toc></xar>"
TOC = zlib.compress(TOC_XML)


def xar_header(magic=b"xar!", size=28, compressed=len(TOC), expanded=len(TOC_XML)):
    return struct.pack(">4sHHQQI", magic, size, 1, compressed, expanded, 0)


def cpio(path, data=b""):
    name = path.encode("utf-8") + b"\0"
    header = b"070707" + b"000000" * 7 + b"00000000000"
    header += f"{len(name):06o}{len(data):011o}".encode("ascii")
    assert len(header) == 76
    return header + name + data


def extract(archive, header=None, toc=TOC):
    payload = bz2.compress(b"\0" * 0x3A4 + archive, compresslevel=9)[4:]
    start = 28 + len(TOC) + 7 + 0x352F40D5
    responses = {
        (0, 27): xar_header() if header is None else header,
        (28, 28 + len(TOC) - 1): toc,
        (start, None): payload,
    }
    calls = []

    def remote(offset, end=None):
        calls.append((offset, end))
        return ShortReads(responses[offset, end], 1)

    with patch.object(assets, "remote", remote):
        assets.download(["Fixture"])
    assert calls == list(responses)


def package_checks():
    with tempfile.TemporaryDirectory(prefix="kbsync-asset-checks-") as temporary:
        destination = Path(temporary)
        image = destination / "Fixture"
        with patch.object(assets, "DEST", destination), patch.object(assets, "IMAGES", {"Fixture": IMAGE_SPEC}):
            assert not assets.valid(image, IMAGE_SPEC)
            assert not assets.valid(destination, IMAGE_SPEC)
            # Skip an unrelated entry larger than the decompressor's output limit.
            extract(cpio("../ignored", bytes(range(256)) * 300) + cpio(IMAGE_PATH, IMAGE) + cpio("TRAILER!!!"))
            assert image.read_bytes() == IMAGE and assets.valid(image, IMAGE_SPEC)
            assert list(destination.iterdir()) == [image]
            for bad in [IMAGE[:-1], b"X" * len(IMAGE)]:
                rejects(ValueError, lambda: assets.publish("Fixture", bad))
                assert image.read_bytes() == IMAGE
                image.write_bytes(bad)
                assert not assets.valid(image, IMAGE_SPEC)
                image.write_bytes(IMAGE)
            for header in [xar_header(magic=b"nope"), xar_header(size=27),
                           xar_header(compressed=4 * 1024 * 1024 + 1),
                           xar_header(expanded=16 * 1024 * 1024 + 1),
                           xar_header(expanded=len(TOC_XML) + 1)]:
                rejects(ValueError, lambda: extract(b"", header=header))
            rejects(EOFError, lambda: extract(b"", header=xar_header()[:-1]))
            rejects(EOFError, lambda: extract(b"", toc=TOC[:-1]))
            rejects(zlib.error, lambda: extract(b"", toc=b"\0" * len(TOC)))
            entry = cpio(IMAGE_PATH, IMAGE)
            for archive in [b"bad!!!" + entry[6:],
                            entry[:59] + b"000000" + entry[65:],
                            entry[:59] + b"010001" + entry[65:],
                            cpio(IMAGE_PATH)[:-1] + b"X",
                            cpio(IMAGE_PATH, IMAGE[:-1]),
                            cpio(IMAGE_PATH, b"X" * len(IMAGE)),
                            cpio("TRAILER!!!")]:
                rejects(ValueError, lambda: extract(archive))
            rejects(EOFError, lambda: extract(entry[:75]))
            rejects(EOFError, lambda: extract(entry[:-1]))
            assert image.read_bytes() == IMAGE and list(destination.iterdir()) == [image]


if __name__ == "__main__":
    with patch.object(assets.urllib.request, "urlopen", side_effect=AssertionError("Network access is forbidden in offline checks")):
        bzip_checks()
        package_checks()
    print("KBSync asset checks passed (offline synthetic bzip/XAR/CPIO and size/SHA-256 validation).")
