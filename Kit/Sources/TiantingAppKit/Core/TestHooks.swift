import CryptoKit
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
        /// `TT_TEST_PICK_DIR=dir`: "图片" and "文件" take the files in this host directory (name order) instead of the system
        /// pickers, which a UI test cannot drive (like Android's `pickForTest`, A26). The files are copied, then left alone.
        static var pickDir: URL? { env["TT_TEST_PICK_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
        private nonisolated(unsafe) static var loadedImages = 0
        private nonisolated(unsafe) static var lastDownload = ""
        static func imageLoaded() { loadedImages += 1 }
        /// The SHA-256 of the last finished file download (AC-FILE-03-1: the test compares it with what it sent).
        static func downloaded(_ url: URL) {
            guard let d = try? Data(contentsOf: url) else { return }
            lastDownload = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        }
        static var imagesLoaded: Int { loadedImages }
        static var lastDownloadSHA: String { lastDownload }

        /// `TT_TEST_SCAN=marker`: how many files in the app's data directory hold these bytes (TC-RCL-03-04: the recalled
        /// text is gone from the local database after a cold start). A count, never content.
        static func scanHits() -> Int {
            guard let needle = env["TT_TEST_SCAN"].map({ Data($0.utf8) }), !needle.isEmpty else { return -1 }
            let fm = FileManager.default
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            guard let e = fm.enumerator(at: home, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
            var n = 0
            for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                if let d = try? Data(contentsOf: u, options: .mappedIfSafe), d.range(of: needle) != nil { n += 1 }
            }
            return n
        }

        /// Files in the SDK's download cache, the SDK's partial `.part-` files, and URLSession's own `CFNetworkDownload_*`
        /// files in tmp (AC-RCL-03-12 "不留部分文件", issue 52). Counts only.
        static func downloadCache() -> (files: Int, parts: Int, urlSession: Int) {
            let fm = FileManager.default
            var files = 0
            var parts = 0
            var urlSession = 0
            if let root = fm.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("tianting-files"),
                let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
            {
                for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    files += 1
                    if u.lastPathComponent.contains(".part-") { parts += 1 }
                }
            }
            let tmp = fm.temporaryDirectory
            for n in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where n.hasPrefix("CFNetworkDownload") {
                urlSession += 1
            }
            return (files, parts, urlSession)
        }
    #else
        static var pickDir: URL? { nil }
        static func imageLoaded() {}
        static func downloaded(_ url: URL) {}
        static func savedSession() {}
        static var forceOffline: Bool { false }
        static var copyFails: Bool { false }
        static var exposesState: Bool { false }
    #endif
}
