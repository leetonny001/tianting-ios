#!/usr/bin/env python3
"""After an end-to-end run: what the app left on the simulator (AC-UI-90-2, AC-UI-90-12; AC-ADM-31-4; NF-UI-13).

  python3 -I scripts/py/check_e2e_leftovers.py UDID "YYYY-MM-DD HH:MM:SS" SERVER_LOG

Checks os_log of the app process for message markers, the app's UserDefaults for keys outside ui.* and for non-numeric
ui.noticeSeen.* values, and the app's data directory for text of deleted messages and of system notices (the notice list is
memory only, the push cursor file has numbers and pushIds). The app container is removed by uninstalling, so run this straight after the tests.
"""
import os
import plistlib
import re
import subprocess
import sys

BUNDLE = "com.tianting.im"
# Keys the system writes into an app's defaults; not ours (the app only writes through UIPrefs).
SYSTEM_KEY = re.compile(r"^(Apple|NS|AK|UI|PK|WebKit|INNextFreshmintRefreshDateKey|INNextHearbeatDate|AddingEmojiKeybordHandled|com\.apple\.)")


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, errors="replace")


def main():
    udid, started = sys.argv[1], sys.argv[2]
    problems = []

    logs = run("xcrun", "simctl", "spawn", udid, "log", "show", "--style", "compact", "--info", "--debug",
               "--start", started, "--predicate",
               # The XCTest agent injected into the app logs the accessibility tree it reads; a release build has no such agent.
               'process == "Tianting" AND NOT (subsystem BEGINSWITH "com.apple.dt.xctest")')
    if logs.returncode != 0:
        problems.append("could not read os_log: " + logs.stderr.strip()[:200])
    text = logs.stdout
    lines = len(text.splitlines())
    # Markers the tests send; "ZXQ-" also covers the deleted-message marker. Chinese test messages too.
    for marker in ["ZXQ-", "很长的消息内容", "收到，周六见", "你好bob"]:
        if marker in text:
            problems.append("os_log contains message text: " + marker)
    if re.search(r"eyJ[A-Za-z0-9_-]{10,}\.", text):
        problems.append("os_log contains something like a JWT")
    print("os_log: %d lines from the app checked" % lines)

    data = run("xcrun", "simctl", "get_app_container", udid, BUNDLE, "data")
    if data.returncode != 0:
        problems.append("no app container: " + data.stderr.strip()[:200])
    else:
        root = data.stdout.strip()
        plist = os.path.join(root, "Library", "Preferences", BUNDLE + ".plist")
        keys = []
        if os.path.exists(plist):
            with open(plist, "rb") as f:
                defaults = plistlib.load(f)
            keys = list(defaults.keys())
            for k, v in defaults.items():
                if k.startswith("ui.noticeSeen.") and not (isinstance(v, str) and v.isdigit()):
                    problems.append("%s is not a plain number" % k)
                if isinstance(v, str) and "ZXQ-" in v:
                    problems.append("UserDefaults %s holds message text" % k)
        bad = [k for k in keys if not k.startswith("ui.") and not SYSTEM_KEY.match(k)]
        print("UserDefaults keys:", sorted(keys))
        if bad:
            problems.append("UserDefaults has non-ui keys: %s" % bad)
        found = []
        notices = []
        for d, _, files in os.walk(root):
            for name in files:
                p = os.path.join(d, name)
                try:
                    with open(p, "rb") as f:
                        blob = f.read()
                except OSError:
                    continue
                if b"ZXQ-DEL-" in blob:
                    found.append(p)
                if b"ZXQ-PUSH-" in blob or "ZXQ-PUSH-".encode("utf-16-be") in blob:
                    notices.append(p)
        if found:
            problems.append("deleted text on disk: %s" % found)
        print("data directory: no deleted text" if not found else "data directory: deleted text found")
        if notices:
            problems.append("notice text on disk: %s" % notices)
        print("data directory: no notice text" if not notices else "data directory: notice text found")

    for p in problems:
        print("PROBLEM:", p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
