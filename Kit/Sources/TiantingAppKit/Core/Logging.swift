import os

/// The app's only log. Takes fixed event names and error codes: there is no way to pass a message, a token, a remark or
/// any other user input (AC-UI-90-12, NF-UI-16). The SDK runs with `SilentLogger`.
public enum TTLog {
    private static let logger = Logger(subsystem: "com.tianting.im", category: "app")

    public static func event(_ name: StaticString) {
        logger.info("\(name.description, privacy: .public)")
    }

    public static func requestError(_ name: StaticString, code: Int) {
        logger.error("\(name.description, privacy: .public) code=\(code, privacy: .public)")
    }
}
