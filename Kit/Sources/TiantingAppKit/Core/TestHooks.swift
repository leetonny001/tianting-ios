import Foundation

/// What only the UI tests can ask of a debug build, through the launch environment. Release builds have none of it.
enum TestHooks {
    #if DEBUG
        private static let env = ProcessInfo.processInfo.environment
        private nonisolated(unsafe) static var saves = 0
        /// Session saves since launch: lets a test see a refresh happen against the real server, no values.
        static var saveCount: Int { saves }

        /// `TT_TEST_EXIT_AFTER_SAVE=n`: dies right after the n-th session save, before the token is used (TC-ACC-03-13).
        static func savedSession() {
            saves += 1
            if env["TT_TEST_EXIT_AFTER_SAVE"] == String(saves) { exit(0) }
        }

        /// `TT_TEST_OFFLINE=1`: the app reads as offline. A simulator shares the Mac's network, so a test cannot take it away.
        static var forceOffline: Bool { env["TT_TEST_OFFLINE"] == "1" }
        /// `TT_TEST_COPY_FAIL=1`: the pasteboard refuses the recovery code (F-ACC 13.4).
        static var copyFails: Bool { env["TT_TEST_COPY_FAIL"] == "1" }
        /// `TT_TEST_STATE=1`: a hidden element tells the tests what the Keychain holds: yes or no and a count, no values.
        static var exposesState: Bool { env["TT_TEST_STATE"] == "1" }
        /// `TT_TEST_LEGACY_SESSION=userId:token`: the previous version's Keychain item (TC-ACC-03-18).
        static var legacySession: (userId: String, token: String)? {
            guard let raw = env["TT_TEST_LEGACY_SESSION"], let i = raw.firstIndex(of: ":") else { return nil }
            return (String(raw[..<i]), String(raw[raw.index(after: i)...]))
        }
    #else
        static func savedSession() {}
        static var forceOffline: Bool { false }
        static var copyFails: Bool { false }
        static var exposesState: Bool { false }
    #endif
}
