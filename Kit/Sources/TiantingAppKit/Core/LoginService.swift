import Foundation
import TiantingIM

public enum LoginOutcome: Equatable, Sendable {
    case success(AccountSession)
    case failure(String)
}

/// Demo login (PRD-ui F-UI-03, F-UI-43 rule 1). The HTTP body carries a username and an optional nickname, nothing else.
public struct DemoLoginService: Sendable {
    public var server: URL?
    public var timeout: TimeInterval = 10

    public init(server: URL?) {
        self.server = server
    }

    private struct Response: Decodable {
        struct Details: Decodable {
            var bannedUntil: Int64?
        }
        var userId: String?
        var token: String?
        var code: Int?
        var details: Details?
    }

    public func login(username: String, nickname: String) async -> LoginOutcome {
        guard let server else { return .failure("登录服务未开启") }
        var request = URLRequest(url: server.appendingPathComponent("demo/login"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["username": username]
        if !nickname.isEmpty { body["nickname"] = nickname }
        request.httpBody = try? JSONEncoder().encode(body)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        do {
            let (data, response) = try await URLSession(configuration: config).data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Self.outcome(status: status, data: data)
        } catch {
            return .failure("网络异常，请稍后重试")
        }
    }

    public static func outcome(status: Int, data: Data) -> LoginOutcome {
        if status == 404 { return .failure("登录服务未开启") }
        let r = try? JSONDecoder().decode(Response.self, from: data)
        // 4034 is not a ws code; its copy lives with the login page (F-UI-43 rule 1).
        if r?.code == 4034 { return .failure(bannedText(until: r?.details?.bannedUntil)) }
        guard (200..<300).contains(status), let token = r?.token, !token.isEmpty, let userId = r?.userId else {
            return .failure(errorText(r?.code ?? 5000))
        }
        return .success(AccountSession(mode: .demo, userId: userId, accessToken: token, accessExpiresAt: 0))
    }
}
