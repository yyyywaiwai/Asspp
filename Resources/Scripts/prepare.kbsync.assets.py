#!/usr/bin/env python3
"""Resolve checksum-pinned Apple runtime images from a cache or Apple's update package."""
import bz2
import hashlib
import os
from pathlib import Path
import shutil
import struct
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zlib

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / "Packages/StoreKBSync/Sources/StoreKBSync/Resources/Assets"
URL = "https://swcdn.apple.com/content/downloads/27/34/041-98128-A_SYPWICN3KH/5dqkl4rqgbsr18yzy61yeie9g3cmjc5hiv/OSXUpd10.9.pkg"
IMAGES = {
    "CommerceKit": (3271840, "b84ff12c21987856c0a17b78f1ad82b73195a6dec5f3b208a17d245555a2c8a2", "./System/Library/PrivateFrameworks/CommerceKit.framework/Versions/A/CommerceKit"),
    "CommerceCore": (207744, "c5401e57402230f3c876409d295319ddf1e61287bc882683c5d61277be7bc1f2", "./System/Library/PrivateFrameworks/CommerceKit.framework/Versions/A/Frameworks/CommerceCore.framework/Versions/A/CommerceCore"),
    "CoreFP": (29014912, "f19141336be4198d0f8991bb00017c915efc7aeaece36c345f7faa1237ea6074", "./System/Library/PrivateFrameworks/CoreFP.framework/Versions/A/CoreFP"),
    "CoreFP.icxs": (5288352, "473e78af86979f5bd4f6269561caf770b3d16c098d918846eeac8cdd2fe6566a", "./System/Library/PrivateFrameworks/CoreFP.framework/Versions/A/CoreFP.icxs"),
    "storeagent": (2580176, "70ce036f9dbcbc04db9511ebd08de0dd3cbc35ccc9d44b089c90170cb5453c59", "./System/Library/PrivateFrameworks/CommerceKit.framework/Versions/A/Resources/storeagent"),
}


def valid(path, spec):
    return path.is_file() and path.stat().st_size == spec[0] and hashlib.sha256(path.read_bytes()).hexdigest() == spec[1]


def publish(name, data):
    spec = IMAGES[name]
    if len(data) != spec[0] or hashlib.sha256(data).hexdigest() != spec[1]:
        raise ValueError("Apple image checksum mismatch: " + name)
    with tempfile.NamedTemporaryFile(dir=DEST, delete=False) as temporary:
        path = Path(temporary.name)
        try:
            temporary.write(data)
            temporary.close()
            path.chmod(0o644)
            os.replace(path, DEST / name)
        finally:
            path.unlink(missing_ok=True)


def remote(start, end=None):
    request = urllib.request.Request(URL, headers={"Range": f"bytes={start}-" + (str(end) if end is not None else "")})
    response = urllib.request.urlopen(request, timeout=60)
    if response.status != 206 or not response.headers.get("Content-Range", "").startswith(f"bytes {start}-"):
        response.close()
        raise ValueError("Apple server did not honor the byte range")
    return response


def exact(stream, size):
    data = bytearray()
    while len(data) < size:
        block = stream.read(size - len(data))
        if not block:
            raise EOFError("Truncated Apple payload")
        data.extend(block)
    return bytes(data)


class BZipStream:
    def __init__(self, response):
        self.source = response
        self.decoder = bz2.BZ2Decompressor()
        self.decoder.decompress(b"BZh9")

    def read(self, count):
        if count == 0:
            return b""
        while not self.decoder.eof:
            block = self.source.read(65536) if self.decoder.needs_input else b""
            if self.decoder.needs_input and not block:
                raise EOFError("Truncated compressed Apple payload")
            data = self.decoder.decompress(block, max_length=min(count, 65536))
            if data:
                return data
        return b""


def skip(stream, count):
    while count:
        block = exact(stream, min(count, 65536))
        count -= len(block)


def download(wanted):
    with remote(0, 27) as response:
        header = exact(response, 28)
    magic, header_size, _, compressed, expanded, _ = struct.unpack(">4sHHQQI", header)
    if magic != b"xar!" or header_size != 28 or compressed > 4 * 1024 * 1024 or expanded > 16 * 1024 * 1024:
        raise ValueError("Unexpected Apple XAR header")
    with remote(header_size, header_size + compressed - 1) as response:
        decoder = zlib.decompressobj()
        toc_data = decoder.decompress(exact(response, compressed), 16 * 1024 * 1024 + 1)
    if len(toc_data) != expanded:
        raise ValueError("Unexpected Apple XAR table size")
    toc = ET.fromstring(toc_data)
    payload = next(item for item in toc.iter("file") if item.findtext("name") == "Payload")
    payload_offset = int(payload.findtext("data/offset"))
    start = header_size + compressed + payload_offset + 0x352F40D5
    with remote(start) as response:
        stream = BZipStream(response)
        skip(stream, 0x3A4)
        by_path = {IMAGES[name][2]: name for name in wanted}
        while by_path:
            header = exact(stream, 76)
            if header[:6] != b"070707":
                raise ValueError("Unexpected Apple CPIO header")
            name_size, file_size = int(header[59:65], 8), int(header[65:76], 8)
            if not 1 <= name_size <= 4096:
                raise ValueError("Invalid CPIO path length")
            raw_name = exact(stream, name_size)
            if raw_name[-1] != 0:
                raise ValueError("Invalid CPIO path terminator")
            path = raw_name[:-1].decode("utf-8")
            if path == "TRAILER!!!":
                raise ValueError("Required Apple image is missing")
            name = by_path.pop(path, None)
            if name:
                if file_size != IMAGES[name][0]:
                    raise ValueError("Unexpected Apple image size")
                publish(name, exact(stream, file_size))
            else:
                skip(stream, file_size)


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    cache = Path.home() / "Library/Caches/ipatool/sap"
    for name, spec in IMAGES.items():
        if valid(DEST / name, spec):
            continue
        cached = cache / ("apple-storeagent-v1" if name == "storeagent" else "apple-assets-v2") / name
        if valid(cached, spec):
            publish(name, cached.read_bytes())
    missing = [name for name, spec in IMAGES.items() if not valid(DEST / name, spec)]
    if missing:
        download(missing)
    assert all(valid(DEST / name, spec) for name, spec in IMAGES.items())
    print("All five Apple runtime images passed size/SHA-256 validation.")


if __name__ == "__main__":
    main()
