import Foundation
import TiantingIM
import TiantingIMTesting

let sdkProtocolDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("tianting-sdk-swift/protocol")

@MainActor
func flush() async {
    for _ in 0..<60 { await Task.yield() }
}

/// A fake-transport client, logged in.
@MainActor
final class Fake {
    let transport = FakeTransport()
    let clock = FakeClock()
    let client: IMClient

    init() {
        var options = IMClientOptions(url: "ws://im.test/ws")
        options.transport = transport
        options.clock = clock
        options.random = { 0.5 }
        options.systemEvents = false
        var n = 0
        options.newId = {
            n += 1
            return "cid-\(n)"
        }
        client = IMClient(options: options)
    }

    func connect(_ user: String = "alice", convs: [JSONValue] = []) async {
        client.connect(token: "t")
        let c = transport.current
        c.open()
        c.ack("auth", ["userId": .string(user), "serverTime": .int(clock.now())])
        await flush()
        c.ack("convs", ["convs": .array(convs), "truncated": false])
        await flush()
    }
}

func convFrame(
    _ convId: String, name: String = "n", maxSeq: Int64 = 0, unread: Int64 = 0, lastMsg: JSONValue = nil,
    memberCount: Int64? = nil
) -> JSONValue {
    var o: [String: JSONValue] = [
        "convId": .string(convId),
        "type": .string(convId.hasPrefix("group:") ? "group" : "c2c"),
        "name": .string(name), "maxSeq": .int(maxSeq), "readSeq": .int(maxSeq - unread), "minSeq": 1,
        "unread": .int(unread), "lastMsg": lastMsg, "updatedAt": 1,
    ]
    if let memberCount { o["memberCount"] = .int(memberCount) }
    return .object(o)
}

private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any?]) -> T {
    let data = try! JSONSerialization.data(withJSONObject: object.compactMapValues { $0 })
    return try! JSONDecoder().decode(T.self, from: data)
}

func message(
    _ id: String, from: String = "alice", status: MessageStatus = .sent, type: MessageType = .text, ts: Int64 = 0,
    deleted: Bool? = nil
) -> Message {
    decode(
        Message.self,
        [
            "clientMsgId": id, "msgId": id, "seq": 1, "convId": "c2c:alice:bob", "from": from, "type": type.rawValue,
            "body": ["text": "t"], "ts": ts, "status": status.rawValue, "deleted": deleted,
        ])
}

func snapshot(_ reason: String?) -> ConversationSnapshot {
    decode(
        ConversationSnapshot.self,
        ["convId": "group:g", "type": "group", "name": "n", "removed": true, "reason": reason])
}

func conversation(_ type: ConvType, last: LastMsg?) -> Conversation {
    let lastObject: [String: Any?]? = last.map {
        ["msgId": $0.msgId, "from": $0.from, "type": $0.type, "text": $0.text, "ts": $0.ts, "deleted": $0.deleted]
    }
    return decode(
        Conversation.self,
        [
            "convId": type == .group ? "group:g1" : "c2c:alice:bob", "type": type.rawValue, "name": "n", "maxSeq": 1,
            "readSeq": 1, "minSeq": 1, "unread": 0, "updatedAt": 1, "lastMsg": lastObject?.compactMapValues { $0 },
        ])
}
