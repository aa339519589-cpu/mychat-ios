#!/usr/bin/env python3
"""Build the bundled heavier Han faces once; no runtime outline processing.

Input: unmodified LXGW WenKai Medium v1.522 (SIL OFL 1.1).
Dependencies: fontTools and FreeType. Pass the FreeType library path explicitly.
The derived family is renamed MyChat Text; original copyright/license retained.
"""
import argparse
import ctypes as C
import hashlib
from pathlib import Path

from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._g_l_y_f import GlyphCoordinates


class Vector(C.Structure):
    _fields_ = [("x", C.c_long), ("y", C.c_long)]


class Outline(C.Structure):
    _fields_ = [("n_contours", C.c_short), ("n_points", C.c_short),
                ("points", C.POINTER(Vector)), ("tags", C.POINTER(C.c_ubyte)),
                ("contours", C.POINTER(C.c_short)), ("flags", C.c_int)]


def build(source, output, lib, style, strength, weight):
    font = TTFont(source, recalcTimestamp=False)
    glyf = font["glyf"]
    original_metrics = {}
    for name in font.getGlyphOrder():
        glyph = glyf[name]
        glyph.recalcBounds(glyf)
        original_metrics[name] = (getattr(glyph, "xMin", 0), getattr(glyph, "yMax", 0))
    for name in font.getGlyphOrder():
        glyph = glyf[name]
        if glyph.numberOfContours <= 0:
            continue
        coords, ends, flags = glyph.getCoordinates(glyf)
        points = (Vector * len(coords))(*(Vector(round(x * 64), round(y * 64)) for x, y in coords))
        tags = (C.c_ubyte * len(flags))(*(flag & 1 for flag in flags))
        contours = (C.c_short * len(ends))(*ends)
        outline = Outline(len(ends), len(coords), points, tags, contours, 0)
        assert lib.FT_Outline_Check(C.byref(outline)) == 0, name
        assert lib.FT_Outline_EmboldenXY(C.byref(outline), strength * 64, strength * 64) == 0, name
        # Center the extra ink without increasing advances or changing baselines.
        glyph.coordinates = GlyphCoordinates([
            (round(p.x / 64 - strength / 2), round(p.y / 64 - strength / 2)) for p in points
        ])
    glyf.removeHinting()
    for table in ("prep", "fpgm", "cvt ", "DSIG"):
        if table in font:
            del font[table]
    for name in font.getGlyphOrder():
        glyph = glyf[name]
        glyph.recalcBounds(glyf)
        old_x, old_y = original_metrics[name]
        advance, bearing = font["hmtx"][name]
        font["hmtx"][name] = (advance, bearing + getattr(glyph, "xMin", 0) - old_x)
        if "vmtx" in font:
            advance, bearing = font["vmtx"][name]
            font["vmtx"][name] = (advance, bearing - getattr(glyph, "yMax", 0) + old_y)
    values = {1: "MyChat Text", 2: style, 3: f"MyChatText-{style};1.522.1",
              4: f"MyChat Text {style}", 5: "Version 1.522.1", 6: f"MyChatText-{style}",
              16: "MyChat Text", 17: style, 18: f"MyChat Text {style}"}
    for record in font["name"].names:
        if record.nameID in values:
            record.string = values[record.nameID].encode(record.getEncoding(), errors="replace")
    font["OS/2"].usWeightClass = weight
    font["OS/2"].fsSelection &= ~((1 << 0) | (1 << 5) | (1 << 6))
    font["OS/2"].fsSelection |= 1 << (5 if weight >= 700 else 6)
    font["head"].macStyle = (font["head"].macStyle & ~3) | (1 if weight >= 700 else 0)
    output.parent.mkdir(parents=True, exist_ok=True)
    font.save(output)
    check = TTFont(output)
    original = TTFont(source)
    assert check.getBestCmap() == original.getBestCmap()
    assert all(check["hmtx"][g][0] == original["hmtx"][g][0] for g in check.getGlyphOrder())
    assert check["glyf"][check.getBestCmap()[ord("字")]].coordinates != original["glyf"][original.getBestCmap()[ord("字")]].coordinates
    print(style, weight, "glyphs", len(check.getGlyphOrder()), "SHA256", hashlib.sha256(output.read_bytes()).hexdigest(), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("freetype_library", type=Path)
    parser.add_argument("output_directory", type=Path)
    args = parser.parse_args()
    assert hashlib.sha256(args.source.read_bytes()).hexdigest() == "d4bdeb38a39151d74d084cba5090f8cb7d20bf83eedb78c35939ae70b9f4e3f6"
    library = C.CDLL(str(args.freetype_library))
    library.FT_Outline_Check.argtypes = [C.POINTER(Outline)]
    library.FT_Outline_EmboldenXY.argtypes = [C.POINTER(Outline), C.c_long, C.c_long]
    build(args.source, args.output_directory / "MyChatText-Semibold.ttf", library, "Semibold", 16, 600)
    build(args.source, args.output_directory / "MyChatText-Bold.ttf", library, "Bold", 24, 700)
