#!/usr/bin/env python3
"""Synthesize Panasonic-shaped MJPEG-over-UDP datagrams for unit tests.

Background: live capture from the real S5D requires an encrypted-
session handshake that this firmware enforces but liblumix doesn't
implement. While we work on that separately, the PR 4 frame-header
parser and JPEG decoder can be unit-tested against synthetic
datagrams. The format is fully documented in SPEC-flutter-app.md
§"Live preview (MJPEG over UDP)":

  bytes [0..29]   header (30 bytes, content undocumented — we use 0)
  bytes [30..31]  BE-16 integer N
  bytes [32..32+N-1]  metadata (overlay rectangles etc.; parser ignores)
  bytes [32+N..]  JPEG payload, starting with SOI (0xFF 0xD8),
                  ending with EOI (0xFF 0xD9)

  Parser rule: SOI offset = (BE-16 at offset 30) + 32

This generator produces three fixture files exercising different
metadata lengths plus a corner case:

  mjpeg_frame_synth_01.bin   N=0    metadata empty; SOI at offset 32
  mjpeg_frame_synth_02.bin   N=16   all-zero metadata
  mjpeg_frame_synth_03.bin   N=32   metadata contains spurious
                                    FF D8 / FF D9 bytes — verifies
                                    the parser uses the offset and
                                    does NOT scan for markers from
                                    byte 32 onwards

The JPEG payload itself is a tiny solid-color image generated with
Pillow so the decoder test can round-trip through dart:ui's JPEG
decoder.

Run once; commit the resulting .bin files alongside the existing
XML fixtures.
"""
import io
import os
import sys
import struct
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("FATAL: Pillow is required (pip install pillow).")
    sys.exit(1)


JPEG_W, JPEG_H = 64, 48        # tiny — keeps fixtures small
JPEG_QUALITY = 80


def make_jpeg() -> bytes:
    """Produce a small valid baseline JPEG with a recognizable
    pattern (left half red, right half blue) so a decoder test
    can sample pixels and assert."""
    img = Image.new("RGB", (JPEG_W, JPEG_H))
    pixels = img.load()
    for y in range(JPEG_H):
        for x in range(JPEG_W):
            pixels[x, y] = (220, 30, 30) if x < JPEG_W // 2 else (30, 60, 220)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=JPEG_QUALITY)
    data = buf.getvalue()
    # Sanity-check the framing.
    assert data[:2] == b"\xff\xd8", "JPEG must start with SOI"
    assert data[-2:] == b"\xff\xd9", "JPEG must end with EOI"
    return data


def build_datagram(metadata: bytes, jpeg: bytes) -> bytes:
    """Assemble a Panasonic-format datagram.

    Layout:
      30 bytes of header (zero-filled), then
      2 bytes BE-16 = len(metadata), then
      metadata bytes, then
      JPEG bytes (SOI..EOI).
    """
    header = bytes(30)
    length = struct.pack(">H", len(metadata))
    return header + length + metadata + jpeg


def write_fixture(path: Path, data: bytes, label: str) -> None:
    path.write_bytes(data)
    soi_offset = struct.unpack(">H", data[30:32])[0] + 32
    print(f"  {path.name}: {len(data)} bytes  "
          f"(meta_len={struct.unpack('>H', data[30:32])[0]}, "
          f"computed SOI offset={soi_offset}, "
          f"byte at offset = {data[soi_offset]:02x} {data[soi_offset+1]:02x})  "
          f"[{label}]")
    # Self-check.
    assert data[soi_offset:soi_offset + 2] == b"\xff\xd8", \
        f"{path.name}: bytes at computed SOI offset are not FF D8"
    assert data[-2:] == b"\xff\xd9", \
        f"{path.name}: bytes at end are not FF D9"


def main(out_dir: str) -> int:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    print(f"=== Synthesize MJPEG fixtures into {out} ===")

    jpeg = make_jpeg()
    print(f"  baseline JPEG: {len(jpeg)} bytes "
          f"({JPEG_W}x{JPEG_H}, q={JPEG_QUALITY})")
    print()

    # Fixture 01: minimum-metadata case (N=0). SOI lands at offset 32.
    f01 = build_datagram(metadata=b"", jpeg=jpeg)
    write_fixture(out / "mjpeg_frame_synth_01.bin", f01,
                  "N=0; SOI at offset 32")

    # Fixture 02: zero-filled metadata of length 16. SOI at offset 48.
    f02 = build_datagram(metadata=bytes(16), jpeg=jpeg)
    write_fixture(out / "mjpeg_frame_synth_02.bin", f02,
                  "N=16; all-zero metadata")

    # Fixture 03: metadata of length 32 deliberately containing
    # FF D8 and FF D9 bytes — confirms the parser uses the length
    # field, not a marker scan.
    # 8 + 2 + 8 + 2 + 12 = 32.
    spurious = bytes(8) + b"\xff\xd8" + bytes(8) + b"\xff\xd9" + bytes(12)
    assert len(spurious) == 32
    f03 = build_datagram(metadata=spurious, jpeg=jpeg)
    write_fixture(out / "mjpeg_frame_synth_03.bin", f03,
                  "N=32; metadata contains spurious FF D8 / FF D9")

    print()
    print("Done. The JPEG payload encodes a 2-tone image:")
    print(f"  left half  ({JPEG_W//2}x{JPEG_H}) red-ish")
    print(f"  right half ({JPEG_W-JPEG_W//2}x{JPEG_H}) blue-ish")
    print("Decoder tests can sample pixels at (8, 24) [red] and "
          "(56, 24) [blue] to verify decoding succeeded.")
    return 0


if __name__ == "__main__":
    default_out = "test/fixtures/lumix"
    out = sys.argv[1] if len(sys.argv) > 1 else default_out
    sys.exit(main(out))
