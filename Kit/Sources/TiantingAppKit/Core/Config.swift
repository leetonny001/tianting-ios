import Foundation

/// Build-time configuration from Info.plist (Config/Info-*.plist). Debug builds can be pointed at a test server through
/// the `TIANTING_SERVER` launch environment; release builds cannot.
public struct AppConfig: Sendable {
    /// `http(s)://host:port`, the base of `/demo/login` and `/ws`. nil when the build has no server.
    public var server: URL?
    /// Demo login is the only login of the first phase (PRD-ui F-UI-03); off in release builds.
    public var demoLogin: Bool
    public var version: String
    public var build: String

    public init(server: URL?, demoLogin: Bool, version: String = "0", build: String = "0") {
        self.server = server
        self.demoLogin = demoLogin
        self.version = version
        self.build = build
    }

    public static func load(bundle: Bundle = .main, env: [String: String] = ProcessInfo.processInfo.environment)
        -> AppConfig
    {
        var server = (bundle.object(forInfoDictionaryKey: "TTServerURL") as? String).flatMap(URL.init(string:))
        if server?.host == nil { server = nil }
        var demo = bundle.object(forInfoDictionaryKey: "TTDemoLogin") as? Bool ?? false
        #if DEBUG
            if let raw = env["TIANTING_SERVER"], let url = URL(string: raw), url.host != nil {
                server = url
                demo = true
            }
        #endif
        return AppConfig(
            server: server,
            demoLogin: demo,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
    }

    /// `ws(s)://host:port/ws`.
    public var webSocketURL: String? {
        guard let server, var c = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        c.path = "/ws"
        return c.string
    }
}
