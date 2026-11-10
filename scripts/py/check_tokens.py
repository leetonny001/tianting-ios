#!/usr/bin/env python3
"""Token checks (AC-UI-90-3, AC-UI-90-5): the contrast list of PRD-ui 6.2 and the hue rule B-2, on design/tokens.json.

  python3 -I scripts/py/check_tokens.py
"""
import colorsys
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PAIRS = [
    ("01", "on.brand", "brand.fill", 4.5), ("02", "on.brand", "brand.fill.pressed", 4.5), ("03", "brand", "surface", 4.5),
    ("04", "brand", "bg", 4.5), ("05", "brand", "surface.selected", 4.5), ("06", "text.primary", "surface", 4.5),
    ("07", "text.primary", "bg", 4.5), ("08", "text.secondary", "surface", 4.5), ("09", "text.secondary", "bg", 4.5),
    ("10", "text.secondary", "chat.bg", 4.5), ("11", "text.secondary", "surface.selected", 4.5),
    ("12", "text.tertiary", "surface", 4.5), ("13", "text.tertiary", "bg", 4.5), ("14", "text.tertiary", "chat.bg", 4.5),
    ("15", "text.tertiary", "surface.selected", 4.5), ("16", "bubble.self.text", "bubble.self.bg", 4.5),
    ("17", "bubble.other.text", "bubble.other.bg", 4.5), ("18", "text.secondary", "bubble.other.bg", 4.5),
    ("19", "danger", "surface", 4.5), ("20", "danger", "chat.bg", 3), ("21", "on.badge", "badge.bg", 4.5),
    ("22", "warning.text", "warning.bg", 4.5), ("23", "border.input", "surface", 3), ("24", "text.tertiary", "chat.bg", 3),
    ("25", "border.input", "bg", 3), ("26", "danger", "bg", 4.5),
    # v1.5 (C5): the pinned conversation background; 31 is the notify-off dot, not text (3:1).
    ("27", "text.primary", "surface.pinned", 4.5), ("28", "text.secondary", "surface.pinned", 4.5),
    ("29", "text.tertiary", "surface.pinned", 4.5), ("30", "danger", "surface.pinned", 4.5),
    ("31", "badge.bg", "surface.pinned", 3),
]


def lum(hexv):
    def ch(i):
        v = int(hexv[i:i + 2], 16) / 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * ch(1) + 0.7152 * ch(3) + 0.0722 * ch(5)


def contrast(a, b):
    x, y = sorted([lum(a), lum(b)], reverse=True)
    return (x + 0.05) / (y + 0.05)


def main():
    with open(os.path.join(ROOT, "design", "tokens.json"), encoding="utf-8") as f:
        tokens = json.load(f)
    problems = []
    for mode, key in (("L", "light"), ("D", "dark")):
        for pid, fg, bg, need in PAIRS:
            if fg not in tokens["color"] or bg not in tokens["color"]:
                problems.append("%s%s: missing token" % (mode, pid))
                continue
            r = contrast(tokens["color"][fg][key], tokens["color"][bg][key])
            if r < need:
                problems.append("%s%s %s / %s: %.2f < %s" % (mode, pid, fg, bg, r, need))
    for c in tokens["avatar"]:
        if contrast("#FFFFFF", c) < 4.5:
            problems.append("avatar %s below 4.5" % c)
    for name, v in tokens["color"].items():
        if not name.startswith(("brand", "bubble.self")):
            continue
        for hexv in (v["light"], v["dark"]):
            r, g, b = (int(hexv[i:i + 2], 16) / 255 for i in (1, 3, 5))
            h, _, s = colorsys.rgb_to_hls(r, g, b)
            if 120 <= h * 360 <= 165 and s > 0.4:
                problems.append("%s %s: in the green hue range" % (name, hexv))
    if problems:
        print("\n".join(problems))
        return 1
    print("tokens: %d contrast pairs and hue rule pass" % (len(PAIRS) * 2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
