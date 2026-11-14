#!/usr/bin/env python3
"""Checks tools/flag-layouts.txt against the flag pictures, then writes
apple/MiMundo/Resources/FlagLayouts.json for the app.

For every flag it samples the picture at a point inside each region of the
flag's layout (a spot clear of emblems), names the nearest palette colour
and compares it with the colour written in the data. Any mismatch fails.

The sample points mirror the region shapes in the app
(Views/FlagOutline.swift) and the region counts in core/src/flags.rs.

Usage: tools/check-flag-layouts.py           (needs macOS `sips`)
"""
import json
import os
import struct
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "tools", "flag-layouts.txt")
FLAGS = os.path.join(ROOT, "apple", "MiMundo", "Resources", "Flags.xcassets")
OUT = os.path.join(ROOT, "apple", "MiMundo", "Resources", "FlagLayouts.json")

# The kid's paint box (core/src/flags.rs PALETTE), as typical flag shades.
PALETTE = {
    "red": [(206, 17, 38), (237, 41, 57), (218, 41, 28), (200, 16, 46), (239, 51, 64)],
    "maroon": [(138, 21, 56), (158, 49, 54), (141, 27, 61)],
    "orange": [(224, 82, 6), (255, 130, 0), (255, 153, 51), (242, 168, 0), (247, 127, 0), (217, 168, 0)],
    "yellow": [(252, 209, 22), (255, 206, 0), (254, 223, 0), (255, 221, 0), (255, 196, 0)],
    "green": [(0, 140, 69), (0, 122, 61), (0, 155, 58), (0, 106, 78), (20, 181, 58), (0, 150, 57)],
    "lightblue": [(180, 215, 244), (24, 195, 223), (116, 172, 223), (106, 206, 255), (65, 137, 221), (0, 153, 204), (0, 173, 216), (0, 119, 139), (96, 183, 223)],
    "blue": [(45, 42, 74), (0, 56, 147), (0, 40, 104), (0, 87, 183), (0, 35, 149), (0, 47, 108), (0, 82, 147), (62, 94, 185)],
    "white": [(255, 255, 255), (245, 245, 245)],
    "black": [(0, 0, 0), (35, 31, 32)],
}

# Shades a kid can't be expected to tell apart; grading accepts either
# (core/src/flags.rs CLOSE_SHADES), so the data may name either one.
CLOSE = [{"blue", "lightblue"}, {"red", "maroon"}]

# Points (x, y as fractions of width and height) inside each region, in
# region order, clear of the usual emblem spots.
SAMPLES = {
    "plain": [(0.04, 0.06)],
    "h2": [(0.9, 0.2), (0.9, 0.8)],
    "h3": [(0.92, 1 / 6), (0.92, 0.5), (0.92, 5 / 6)],
    "h4": [(0.9, 0.125), (0.9, 0.375), (0.9, 0.625), (0.9, 0.875)],
    "h5": [(0.92, 0.1), (0.92, 0.25), (0.92, 0.5), (0.92, 0.75), (0.92, 0.9)],
    "v2": [(0.1, 0.92), (0.9, 0.92)],
    "v3": [(0.1, 0.95), (0.5, 0.95), (0.9, 0.95)],
    "nordic": [(0.12, 0.12), (0.9, 0.5)],
    "nordic-bordered": [(0.12, 0.12), (0.9, 0.41), (0.9, 0.5)],
    "cross": [(0.08, 0.08), (0.5, 0.5)],
    "cross-quartered": [(0.08, 0.08), (0.92, 0.08), (0.08, 0.92), (0.92, 0.92), (0.97, 0.5)],
    "quarters": [(0.08, 0.08), (0.92, 0.08), (0.08, 0.92), (0.92, 0.92)],
    "disc": [(0.04, 0.06), (0.47, 0.5)],
    "h3-disc": [(0.04, 0.08), (0.04, 0.5), (0.04, 0.92), (0.5, 0.5)],
    "tri-h2": [(0.94, 0.15), (0.94, 0.85), (0.04, 0.5)],
    "tri-h3": [(0.94, 1 / 6), (0.94, 0.5), (0.94, 5 / 6), (0.04, 0.5)],
    "tri-h5": [(0.95, 0.1), (0.95, 0.3), (0.95, 0.5), (0.95, 0.7), (0.95, 0.9), (0.04, 0.5)],
    "bar-h2": [(0.05, 0.5), (0.9, 0.25), (0.9, 0.75)],
    "bar-h3": [(0.05, 0.5), (0.9, 1 / 6), (0.9, 0.5), (0.9, 5 / 6)],
    "saltire": [(0.5, 0.04), (0.04, 0.5), (0.25, 0.25)],
    "diagonal": [(0.04, 0.06), (0.5, 0.5), (0.96, 0.94)],
    "diagonal-split": [(0.04, 0.06), (0.96, 0.94)],
    "canton": [(0.9, 0.9), (0.03, 0.04)],
    "canton-h2": [(0.9, 0.25), (0.5, 0.9), (0.03, 0.04)],
    "diamond": [(0.03, 0.04), (0.2, 0.5), (0.5, 0.33)],
}

# Flags whose regions sit off the usual spots in their 4:3 picture.
SAMPLE_OVERRIDES = {
    "sb": {1: (0.5, 0.7)},  # its band misses the middle of the 4:3 crop
}


def read_bmp(path):
    """Pixels of an uncompressed 24/32-bit BMP as (width, height, getter)."""
    data = open(path, "rb").read()
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0]
    step = bpp // 8
    row = (width * step + 3) & ~3
    flipped = height > 0
    height = abs(height)

    def pixel(x, y):
        yy = height - 1 - y if flipped else y
        i = offset + yy * row + x * step
        b, g, r = data[i], data[i + 1], data[i + 2]
        return (r, g, b)

    return width, height, pixel


def nearest(rgb):
    def dist(a, b):
        return sum((p - q) ** 2 for p, q in zip(a, b))
    return min(PALETTE, key=lambda name: min(dist(rgb, ref) for ref in PALETTE[name]))


def main():
    entries = {}
    for number, line in enumerate(open(SOURCE), 1):
        line = line.split("#", 1)[0].split()
        if not line:
            continue
        code, layout, *rest = line
        emblem = rest[-1:] == ["emblem"]
        colours = rest[:-1] if emblem else rest
        if layout not in SAMPLES:
            sys.exit(f"line {number}: unknown layout {layout}")
        if len(colours) != len(SAMPLES[layout]):
            sys.exit(f"line {number}: {code} needs {len(SAMPLES[layout])} colours for {layout}")
        if code in entries:
            sys.exit(f"line {number}: {code} twice")
        for colour in colours:
            if colour not in PALETTE:
                sys.exit(f"line {number}: unknown colour {colour}")
        entries[code] = {"layout": layout, "colors": colours, "emblem": emblem}

    problems = []
    with tempfile.TemporaryDirectory() as tmp:
        for code, entry in entries.items():
            png = os.path.join(FLAGS, f"flag-{code}.imageset", f"flag-{code}.png")
            if not os.path.exists(png):
                problems.append(f"{code}: no flag picture")
                continue
            bmp = os.path.join(tmp, f"{code}.bmp")
            subprocess.run(["sips", "-s", "format", "bmp", png, "--out", bmp],
                           check=True, capture_output=True)
            width, height, pixel = read_bmp(bmp)
            points = list(SAMPLES[entry["layout"]])
            for i, point in SAMPLE_OVERRIDES.get(code, {}).items():
                points[i] = point
            for i, ((fx, fy), want) in enumerate(zip(points, entry["colors"])):
                x = min(width - 1, int(fx * width))
                y = min(height - 1, int(fy * height))
                rgb = pixel(x, y)
                got = nearest(rgb)
                if got != want and {got, want} not in CLOSE:
                    problems.append(f"{code} {entry['layout']} region {i}: data says {want}, "
                                    f"picture has {got} {rgb}")

    if problems:
        print("\n".join(problems))
        sys.exit(f"{len(problems)} mismatches")
    with open(OUT, "w") as f:
        json.dump(dict(sorted(entries.items())), f, indent=1, sort_keys=True)
        f.write("\n")
    print(f"{len(entries)} flag outlines checked -> {os.path.relpath(OUT, ROOT)}")


if __name__ == "__main__":
    main()
