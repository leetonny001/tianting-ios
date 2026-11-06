import Foundation

/// Build-time configuration from Info.plist (Config/Info-*.plist). Debug builds can be pointed at a test server through
/// the `TIANTING_SERVER` launch environment; release builds cannot.
public struct AppConfig: Sendable {
    /// `http(s)://host:port`, the base of `/demo/login` and `/ws`. nil when the build has no server.
    public var server: URL?
    /// The build's switch for demo login: an upper limit, `GET /v1/config` has to say yes as well (F-ACC-07 rule 4). Off in
    /// release builds.
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
            if env["TT_BUILD_DEMO_LOGIN"] == "0" { demo = false }  // TC-ACC-07-07.
        #endif
        return AppConfig(
            server: server,
            demoLogin: demo,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
    }

    /// The base of `/v1/*`, without a trailing slash.
    public var apiBase: String {
        var s = server?.absoluteString ?? "https://invalid.invalid"
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// `ws(s)://host:port/ws`.
    public var webSocketURL: String? {
        guard let server, var c = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        c.path = "/ws"
        return c.string
    }
}
