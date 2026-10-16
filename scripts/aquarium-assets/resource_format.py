#!/usr/bin/env python3
"""Validated node, mesh and DDS readers for the aquarium asset build pipeline."""
import math
from pathlib import Path
import struct


class Reader:
    def __init__(self, data):
        self.data, self.pos, self.count = data, 0, 0

    def take(self, size):
        if size < 0 or self.pos + size > len(self.data):
            raise ValueError(f"Truncated data at {self.pos:#x}")
        value = self.data[self.pos:self.pos + size]
        self.pos += size
        return value

    def node(self, depth=0):
        self.count += 1
        if depth > 32 or self.count > 1024:
            raise ValueError("Node limits exceeded")
        offset = self.pos
        kind = self.take(4).decode("ascii")
        if kind not in {"fram", "fXfm", "mesh", "mshN", "txtL", "mtlL", "matl", "txtf", "vdup"}:
            raise ValueError(f"Unsupported node {kind!r} at {offset:#x}")
        name = self.take(self.take(1)[0]).decode("mac_roman")
        children = []
        while self.data[self.pos:self.pos + 4] != b"none":
            children.append(self.node(depth + 1))
        self.take(4)
        size, = struct.unpack(">I", self.take(4))
        payload = self.take(size)
        return dict(kind=kind, name=name, children=children, data=payload, offset=offset)


def child(node, kind):
    return next(c for c in node["children"] if c["kind"] == kind)


def mesh_data(data):
    r = Reader(data)
    count, = struct.unpack(">H", r.take(2))
    points = [list(struct.unpack(">3f", r.take(12))) for _ in range(count)]
    faces, = struct.unpack(">H", r.take(2))
    indices = list(struct.unpack(f">{faces * 3}H", r.take(faces * 6)))
    if r.pos != len(data) or not points or max(indices) >= count:
        raise ValueError("Mesh length/index mismatch")
    if not all(math.isfinite(v) for p in points for v in p):
        raise ValueError("Non-finite mesh")
    return points, indices


def decode_dds(path):
    b = path.read_bytes()
    kind = b[84:88]
    if len(b) < 128 or b[:4] != b"DDS " or kind not in {b"DXT1", b"DXT3", b"DXT5"}:
        raise ValueError("Unsupported DDS format")
    height, width = struct.unpack_from("<II", b, 12)
    if width > 2048 or height > 2048 or width % 4 or height % 4:
        raise ValueError("Unsupported DDS dimensions")
    out = bytearray(width * height * 4)
    offset = 128
    for by in range(height // 4):
        for bx in range(width // 4):
            size = 8 if kind == b"DXT1" else 16
            block = b[offset:offset + size]
            if len(block) != size:
                raise ValueError("Truncated DDS block")
            offset += size
            c0, c1, bits = struct.unpack("<HHI", block[-8:])
            alphas = [255] * 16
            if kind == b"DXT3":
                alpha = int.from_bytes(block[:8], "little")
                alphas = [(alpha >> (j * 4) & 15) * 17 for j in range(16)]
            elif kind == b"DXT5":
                a, z = block[0], block[1]
                table = [a, z] + ([(a * (7 - i) + z * i) // 7 for i in range(1, 7)] if a > z else [(a * (5 - i) + z * i) // 5 for i in range(1, 5)] + [0, 255])
                alpha_bits = int.from_bytes(block[2:8], "little")
                alphas = [table[alpha_bits >> (j * 3) & 7] for j in range(16)]
            def rgb(c):
                return [(c >> 11 & 31) * 255 // 31, (c >> 5 & 63) * 255 // 63, (c & 31) * 255 // 31]
            p, q = rgb(c0), rgb(c1)
            colors = [p, q, [(2 * a + z) // 3 for a, z in zip(p, q)], [(a + 2 * z) // 3 for a, z in zip(p, q)]]
            if kind == b"DXT1" and c0 <= c1:
                colors = [p, q, [(a + z) // 2 for a, z in zip(p, q)], [0, 0, 0]]
            for j in range(16):
                x, y = bx * 4 + j % 4, by * 4 + j // 4
                index = bits >> (j * 2) & 3
                alpha = 0 if kind == b"DXT1" and c0 <= c1 and index == 3 else alphas[j]
                out[(y * width + x) * 4:(y * width + x) * 4 + 4] = bytes(colors[index] + [alpha])
    return width, height, bytes(out)


def decode_dxt3(path):
    if path.read_bytes()[84:88] != b"DXT3":
        raise ValueError("Expected DXT3")
    return decode_dds(path)
