#!/usr/bin/env python3
"""Generates the icon asset catalog from Lucide (ISC, LICENSES/lucide.txt; PRD-ui 6.6).

Reads the icon definitions in ../tianting-web/node_modules/lucide-react. Only needed when the icon list changes; the
output is committed.

  python3 -I scripts/py/gen_icons.py
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LUCIDE = os.path.join(ROOT, "..", "tianting-web", "node_modules", "lucide-react", "dist", "esm", "icons")
OUT = os.path.join(ROOT, "Kit", "Sources", "TiantingAppKit", "Resources", "Icons.xcassets")

ICONS = {
    "chats": "message-square-text",
    "contacts": "book-user",
    "me": "circle-user-round",
    "plus": "circle-plus",
    "addFriend": "user-plus",
    "forward": "chevron-right",
    "more": "ellipsis",
    "failed": "circle-alert",
    "loading": "loader-circle",
    "smile": "smile",
    "users": "users",
    "newFriends": "user-round-plus",
    "groups": "messages-square",
    "settings": "settings",
    "image": "image",
    "file": "file",
    "close": "x",
    # The notify-off mark in the conversation list (C5, PRD-ui 6.6 v1.5).
    "notifyOff": "bell-off",
    # The report sheet's title (C6, frontend-chat 80; PRD-ui 6.6 v1.6).
    "report": "flag",
}


def elements(name):
    with open(os.path.join(LUCIDE, name + ".mjs"), encoding="utf-8") as f:
        src = f.read()
    alias = re.search(r"export \{ default \} from './([\w-]+)\.mjs'", src)
    if alias:
        return elements(alias.group(1))
    found = re.findall(r'\[\s*"(\w+)",\s*\{([^}]*)\}\s*\]', src)
    if not found:
        raise SystemExit("no elements in " + name)
    out = []
    for tag, attrs in found:
        pairs = re.findall(r'(\w+):\s*"([^"]*)"', attrs)
        out.append("<%s %s/>" % (tag, " ".join('%s="%s"' % (k, v) for k, v in pairs if k != "key")))
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
    for key, lucide in ICONS.items():
        d = os.path.join(OUT, "icon-%s.imageset" % key)
        os.makedirs(d, exist_ok=True)
        svg = (
            '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            'stroke="black" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">'
            + "".join(elements(lucide))
            + "</svg>\n"
        )
        with open(os.path.join(d, lucide + ".svg"), "w") as f:
            f.write(svg)
        with open(os.path.join(d, "Contents.json"), "w") as f:
            json.dump(
                {
                    "images": [{"filename": lucide + ".svg", "idiom": "universal"}],
                    "info": {"author": "xcode", "version": 1},
                    "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
                },
                f,
                indent=2,
            )
    print("wrote", len(ICONS), "icons")
    return 0


if __name__ == "__main__":
    sys.exit(main())
