#!/usr/bin/env python3
"""Builds the Tapeloop wordmark ("tapel" + cassette + "p") as fixed SVG outlines.

The wordmark is drawn once, here, so its spacing never depends on a browser or a font being installed. The letters are
Space Grotesk Bold (SIL Open Font License), shaped with HarfBuzz (kerning included) and traced to paths. The cassette
replaces the "oo" and is spaced like a letter:

    gap("l" ink -> cassette ink) == gap(cassette ink -> "p" ink) == the font's own gap between "e" and "l"

and the cassette body sits on the baseline. Outputs (Resources/Brand/):
    wordmark.svg              fill="currentColor", for inline use
    wordmark-on-light.svg     ink #161616, for light backgrounds (README <picture>)
    wordmark-on-dark.svg      ink #F4F4F5, for dark backgrounds

Usage:  python3 -m venv .venv && .venv/bin/pip install fonttools uharfbuzz
        .venv/bin/python scripts/brand/make_wordmark.py [path/to/SpaceGrotesk[wght].ttf]
Without a path, the font is downloaded from the google/fonts repository.
"""

from __future__ import annotations

import io
import sys
import urllib.request
from pathlib import Path

import uharfbuzz as hb
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

FONT_URL = "https://github.com/google/fonts/raw/main/ofl/spacegrotesk/SpaceGrotesk%5Bwght%5D.ttf"
WEIGHT = 700
TRACKING_EM = -0.03          # the wordmark's letter-spacing
CASSETTE_UNIT_EM = 0.82 / 17  # cassette design units -> em (body 13.2 units ~ 0.64 em)
PAD_EM = 0.04                 # empty margin around the ink in the SVG

# The cassette, in its design units (x right, y down), body 20.8 x 13.2 with corner radius 0.9.
# The notch is 2.2 deep at the top; the reels (r 3.25, hubs r 1.2) sit with equal 2.6 gaps left, between and right,
# centred in the space below the notch (2.25 above and below them).
BODY_W, BODY_H, CORNER = 20.8, 13.2, 0.9
NOTCH_TOP_HALF = (5.06875 - 0.5, 16.73125 - 0.5)   # where the notch's slanted sides meet the top edge (x from body left)
NOTCH_BOTTOM = (6.1 - 0.5, 15.7 - 0.5)              # the notch floor's ends
NOTCH_DEPTH = 2.2
REEL_X = (6.35 - 0.5, 15.45 - 0.5)
REEL_Y_FROM_TOP = 7.7                                 # 2.2 notch + 2.25 gap + 3.25 radius
REEL_R, HUB_R = 3.25, 1.2


def load_font(path: str | None) -> bytes:
    if path:
        return Path(path).read_bytes()
    with urllib.request.urlopen(FONT_URL) as response:
        return response.read()


def bold_instance(data: bytes) -> tuple[TTFont, bytes]:
    font = TTFont(io.BytesIO(data))
    if "fvar" in font:
        font = instantiateVariableFont(font, {"wght": WEIGHT})
    out = io.BytesIO()
    font.save(out)
    blob = out.getvalue()
    return TTFont(io.BytesIO(blob)), blob


def shape(blob: bytes, text: str) -> list[tuple[str, float]]:
    """Glyph names and pen x positions (font units), kerning and tracking applied."""
    face = hb.Face(blob)
    hb_font = hb.Font(face)
    buf = hb.Buffer()
    buf.add_str(text)
    buf.guess_segment_properties()
    hb.shape(hb_font, buf, {"kern": True, "liga": False})
    upem = face.upem
    names = [hb_font.glyph_to_string(info.codepoint) for info in buf.glyph_infos]
    x, out = 0.0, []
    for name, pos in zip(names, buf.glyph_positions):
        out.append((name, x + pos.x_offset))
        x += pos.x_advance + TRACKING_EM * upem
    return out


def glyph_path(glyphs, name: str, dx: float) -> tuple[str, tuple[float, float, float, float]]:
    pen = SVGPathPen(glyphs)
    glyphs[name].draw(TransformPen(pen, (1, 0, 0, 1, dx, 0)))
    bounds = BoundsPen(glyphs)
    glyphs[name].draw(TransformPen(bounds, (1, 0, 0, 1, dx, 0)))
    return pen.getCommands(), bounds.bounds


def circle(cx: float, cy: float, r: float) -> str:
    return f"M{cx - r:.2f} {cy:.2f}A{r:.2f} {r:.2f} 0 1 0 {cx + r:.2f} {cy:.2f}A{r:.2f} {r:.2f} 0 1 0 {cx - r:.2f} {cy:.2f}Z"


def cassette_path(left: float, unit: float) -> str:
    """The cassette in font coordinates (y up, baseline 0), one even-odd path: body with the notch in its outline,
    reel holes, hubs. Tracing the notch as part of the outline (not a separate cut) leaves no hairline."""
    L, R, B, T, c = left, left + BODY_W * unit, 0.0, BODY_H * unit, CORNER * unit
    n1, n2 = (left + x * unit for x in NOTCH_TOP_HALF)
    f1, f2 = (left + x * unit for x in NOTCH_BOTTOM)
    nf = T - NOTCH_DEPTH * unit
    body = (
        f"M{L + c:.2f} {B:.2f}H{R - c:.2f}A{c:.2f} {c:.2f} 0 0 1 {R:.2f} {B + c:.2f}V{T - c:.2f}"
        f"A{c:.2f} {c:.2f} 0 0 1 {R - c:.2f} {T:.2f}H{n2:.2f}L{f2:.2f} {nf:.2f}H{f1:.2f}L{n1:.2f} {T:.2f}"
        f"H{L + c:.2f}A{c:.2f} {c:.2f} 0 0 1 {L:.2f} {T - c:.2f}V{B + c:.2f}A{c:.2f} {c:.2f} 0 0 1 {L + c:.2f} {B:.2f}Z"
    )
    cy = T - REEL_Y_FROM_TOP * unit
    reels = "".join(circle(left + x * unit, cy, REEL_R * unit) + circle(left + x * unit, cy, HUB_R * unit) for x in REEL_X)
    return body + reels


def build(font_path: str | None) -> dict[str, str]:
    font, blob = bold_instance(load_font(font_path))
    upem = font["head"].unitsPerEm
    glyphs = font.getGlyphSet()

    word = shape(blob, "tapel")
    paths, bounds = [], {}
    for name, x in word:
        d, b = glyph_path(glyphs, name, x)
        paths.append(d)
        bounds[name] = b
    e_name, l_name = word[3][0], word[4][0]
    target = bounds[l_name][0] - bounds[e_name][2]  # the font's own e -> l ink gap

    unit = CASSETTE_UNIT_EM * upem
    cassette_left = bounds[l_name][2] + target
    cassette_index = len(paths)
    paths.append(cassette_path(cassette_left, unit))
    cassette_right = cassette_left + BODY_W * unit

    p_name = shape(blob, "p")[0][0]
    _, p_bounds_at_0 = glyph_path(glyphs, p_name, 0)
    p_x = cassette_right + target - p_bounds_at_0[0]
    d, p_bounds = glyph_path(glyphs, p_name, p_x)
    paths.append(d)

    gap_left = cassette_left - bounds[l_name][2]
    gap_right = p_bounds[0] - cassette_right
    assert abs(gap_left - gap_right) < 0.01, (gap_left, gap_right)

    xs = [b[0] for b in bounds.values()] + [p_bounds[0]]
    xe = [b[2] for b in bounds.values()] + [p_bounds[2]]
    ys = [b[1] for b in bounds.values()] + [p_bounds[1], 0]
    ye = [b[3] for b in bounds.values()] + [p_bounds[3], BODY_H * unit]
    pad = PAD_EM * upem
    x0, x1, y0, y1 = min(xs) - pad, max(xe) + pad, min(ys) - pad, max(ye) + pad
    width, height = x1 - x0, y1 - y0
    print(
        f"gaps (font units of {upem}): l->cassette {gap_left:.1f}, cassette->p {gap_right:.1f}, e->l {target:.1f}; "
        f"viewBox {width:.0f} x {height:.0f}"
    )

    def svg(fill: str) -> str:
        # Letters keep the font's non-zero winding; only the cassette uses even-odd (its holes and hubs).
        body = "".join(
            f'<path d="{p}" fill-rule="evenodd"/>' if i == cassette_index else f'<path d="{p}"/>'
            for i, p in enumerate(paths)
        )
        return (
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{x0:.1f} {-y1:.1f} {width:.1f} {height:.1f}" '
            f'width="{width / upem * 100:.1f}" height="{height / upem * 100:.1f}" role="img" aria-label="Tapeloop">'
            f'<g fill="{fill}" transform="scale(1 -1)">{body}</g></svg>\n'
        )

    return {
        "wordmark.svg": svg("currentColor"),
        "wordmark-on-light.svg": svg("#161616"),
        "wordmark-on-dark.svg": svg("#F4F4F5"),
    }


def main() -> None:
    out_dir = Path(__file__).resolve().parents[2] / "Resources" / "Brand"
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, text in build(sys.argv[1] if len(sys.argv) > 1 else None).items():
        (out_dir / name).write_text(text)
        print(f"wrote {out_dir / name}")


if __name__ == "__main__":
    main()
