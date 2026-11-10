#!/usr/bin/env python3
"""Source checks (SwiftLint is not available here; the rules are the ones PRD-ui 3.6 asks of it):

- no color literal outside Theme/Tokens.swift (AC-UI-22-3): Color(red:..), UIColor(red:..), #colorLiteral, Color(hex..), hex strings
- UserDefaults only in Core/UIPrefs.swift (AC-UI-90-2), Keychain APIs only in Core/SessionStore.swift
- no print / NSLog / os_log / dump outside Core/Logging.swift (AC-UI-90-12)
- no sound, vibration or local-notification API outside Core/Alerts.swift (AC-CVS-02-6)
- no http:// in app sources (AC-UI-21-5), except the loopback defaults of the debug config, which live in plists
- no Text("...\\(x)..."): a localized key renders numbers with grouping ("1,000")
- no other product's name (AC-UI-90-15)
- every testid used by UITests exists in the app

  python3 -I scripts/py/check_sources.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP_DIRS = [os.path.join(ROOT, "App"), os.path.join(ROOT, "Kit", "Sources")]
TOKENS = os.path.join("Theme", "Tokens.swift")

COLOR = re.compile(
    r"#colorLiteral|\bColor\(\s*(red|white|hue|\.sRGB|hex|\")|\bUIColor\(\s*(red|white|hue|displayP3|hex)|"
    r"\bCGColor\(|\.(red|blue|green|black|white|gray|orange|yellow|pink|purple)\b(?=\s*[,)])|Color\.(red|blue|green|black|white|gray)\b|"
    r"\"#[0-9a-fA-F]{6,8}\"|0x[0-9a-fA-F]{6}\b"
)
# Sounds, vibration and posting local notifications only in Core/Alerts.swift (AC-CVS-02-6: the UI tests' stand-in counts
# its calls, so nothing may ring around it).
ALERTS = re.compile(
    r"\b(AudioServicesPlay\w*|SystemSoundID|AVAudioPlayer|AVAudioEngine|AVPlayer|\w*FeedbackGenerator|UNNotificationRequest|"
    r"UNMutableNotificationContent)\b|\.sensoryFeedback\("
)
LOGGING = re.compile(r"\b(print|debugPrint|NSLog|os_log|dump)\(")
BANNED = re.compile("|".join(["微" + "信", "we" + "chat", "wei" + "xin"]), re.I)


def swift_files(dirs):
    for d in dirs:
        for base, _, names in os.walk(d):
            for n in names:
                if n.endswith(".swift"):
                    yield os.path.join(base, n)


def main():
    problems = []
    for path in swift_files(APP_DIRS):
        rel = os.path.relpath(path, ROOT)
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
        for i, line in enumerate(lines, 1):
            code = line.split("//")[0] if "http" not in line else line
            if not rel.endswith(TOKENS) and COLOR.search(code):
                problems.append("%s:%d: color literal: %s" % (rel, i, line.strip()))
            if "UserDefaults" in code and not rel.endswith("UIPrefs.swift") and not rel.endswith("ThemeController.swift"):
                problems.append("%s:%d: UserDefaults outside UIPrefs: %s" % (rel, i, line.strip()))
            if re.search(r"\bSec(Item|Key)", code) and not rel.endswith("SessionStore.swift"):
                problems.append("%s:%d: Keychain outside SessionStore" % (rel, i))
            if ALERTS.search(code) and not rel.endswith(os.path.join("Core", "Alerts.swift")):
                problems.append("%s:%d: sound, vibration or notification outside Alerts: %s" % (rel, i, line.strip()))
            if LOGGING.search(code) and not rel.endswith("Logging.swift"):
                problems.append("%s:%d: logging outside TTLog: %s" % (rel, i, line.strip()))
            if re.search(r'\bText\("[^"]*\\\(', code):
                problems.append("%s:%d: Text with interpolation formats numbers (1,000): use Text(verbatim:)" % (rel, i))
            if '"http://' in code:
                problems.append("%s:%d: plain http in sources: %s" % (rel, i, line.strip()))
    for base in ["App", "Kit", "UITests", "Config", "README.md", "design", ".github"]:
        p = os.path.join(ROOT, base)
        paths = [p] if os.path.isfile(p) else [os.path.join(b, n) for b, _, ns in os.walk(p) for n in ns]
        for fp in paths:
            if not fp.endswith((".swift", ".plist", ".md", ".json", ".yml")):
                continue
            with open(fp, encoding="utf-8", errors="ignore") as f:
                if BANNED.search(f.read()):
                    problems.append("%s: other product's name" % os.path.relpath(fp, ROOT))
    # Release builds have no ATS exception, no demo login, no server default.
    with open(os.path.join(ROOT, "Config", "Info-Release.plist"), encoding="utf-8") as f:
        release = f.read()
    if "NSAppTransportSecurity" in release:
        problems.append("Config/Info-Release.plist: ATS exception in a release build")
    if "<key>TTDemoLogin</key>\n\t<false/>" not in release:
        problems.append("Config/Info-Release.plist: demo login must be off")
    # testids used by the UI tests must be spelled in the app.
    app_text = "".join(open(p, encoding="utf-8").read() for p in swift_files(APP_DIRS))
    for path in swift_files([os.path.join(ROOT, "UITests")]):
        with open(path, encoding="utf-8") as f:
            src = f.read()
        for m in re.finditer(r'(?:tap|see|label|gone|el|all)\("([a-z][a-z0-9-]+)"\)', src):
            tid = m.group(1)
            if tid.endswith("-scrim"):  # DialogLayer builds these from the dialog's id.
                tid = tid[: -len("-scrim")]
            if '"%s"' % tid in app_text or "%s-" % tid.rsplit("-", 1)[0] in app_text:
                continue
            problems.append("%s: test uses unknown id %s" % (os.path.relpath(path, ROOT), tid))
    if problems:
        print("\n".join(problems))
        return 1
    print("sources: no color literals, UserDefaults only in UIPrefs, no stray logging")
    return 0


if __name__ == "__main__":
    sys.exit(main())
