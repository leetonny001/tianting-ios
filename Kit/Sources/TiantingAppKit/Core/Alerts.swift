import Foundation

/// The one place for a message's sound, vibration or local notification (scripts/py/check_sources.py keeps the system
/// APIs for them out of every other file). C5 has none at all: a message arriving in the foreground rings nothing, and a
/// conversation with notifications off must stay silent once C3 adds them (PRD-chat F-CVS-02 rule 6, AC-CVS-02-6,
/// frontend-chat 58; FE-655 reruns TC-CVS-02-06 then). Debug builds count each call: the UI tests' stand-in for a sound.
enum Alerts {
    static func ring() {
        TestHooks.alerted()
    }
}
