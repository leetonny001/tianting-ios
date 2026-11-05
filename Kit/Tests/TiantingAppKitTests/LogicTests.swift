import XCTest

import TiantingIM
@testable import TiantingAppKit

@MainActor
final class ErrorCopyTests: XCTestCase {
    /// AC-UI-19-3: every ws code in errors.json has copy, and copy never comes back blank.
    func testEveryWsCodeHasCopy() throws {
        let data = try Data(contentsOf: sdkProtocolDir.appendingPathComponent("errors.json"))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let list = (root["errors"] as? [[String: Any]]) ?? []
        XCTAssertFalse(list.isEmpty)
        var checked = 0
        for e in list {
            guard let code = e["code"] as? Int else { continue }
            let scope = e["scope"] as? String
            if scope == "admin" || scope == "console" { continue }
            XCTAssertFalse(errorText(code).isEmpty, "\(code)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 10)
    }

    /// AC-UI-19-3: the "command + code" table of vectors/social.json.
    func testCommandCopyVectors() throws {
        let data = try Data(contentsOf: sdkProtocolDir.appendingPathComponent("vectors/social.json"))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let copy = root["copy"] as? [[String: Any]] ?? []
        XCTAssertFalse(copy.isEmpty)
        for c in copy {
            let cmd = c["cmd"] as! String
            let code = c["code"] as! Int
            // The table has templates: {N} for the limit, {name} for a person.
            let expected = (c["text"] as! String)
                .replacingOccurrences(of: "{N}", with: "3")
                .replacingOccurrences(of: "{name}", with: "bob")
            XCTAssertEqual(errorText(code, cmd: cmd, strangerMsgLimit: 3, name: "bob"), expected, "\(cmd) \(code)")
        }
    }

    func testDefaultsAndUnknown() {
        XCTAssertEqual(errorText(4042), "用户不存在")  // AC-UI-19-1
        XCTAssertEqual(errorText(4001), "当前版本过低，请刷新页面")  // AC-UI-19-5
        XCTAssertEqual(errorText(4008), "请求出错")
        XCTAssertEqual(errorText(4999), "请求出错")  // C-09
        XCTAssertEqual(errorText(5999), "服务异常，请稍后重试")
        XCTAssertEqual(errorText(4292, cmd: "friendApply"), "今天的次数已用完，明天再试")  // AC-UI-19-4
        XCTAssertEqual(errorText(4292, cmd: "send"), "今天发起新聊天的次数已用完，请稍后再试")
        XCTAssertEqual(errorText(4290, cmd: "send"), "发送太频繁，请稍后再试")  // AC-UI-08-3
        XCTAssertEqual(errorText(4290, cmd: "setPrivacy"), "操作太频繁，请稍后再试")  // AC-UI-30-2
        XCTAssertEqual(errorText(4000, cmd: "friendApply"), "请先将对方移出黑名单")
        XCTAssertEqual(errorText(4040, cmd: "friendRemark"), "对方已不在你的通讯录中")  // AC-UI-28-5
        XCTAssertEqual(errorText(4136, cmd: "groupSetAdmin"), "管理员最多 10 人")  // AC-UI-38-6
        XCTAssertEqual(errorText(4030, cmd: "groupCreate"), "当前不允许创建群聊")  // AC-UI-35-5
        XCTAssertEqual(errorText(4045, cmd: "friendRespond"), "该申请已过期")  // AC-UI-25-7
    }

    func testFatalText() {
        // AC-UI-18-2, AC-UI-43-4
        XCTAssertEqual(
            fatalText(.kicked(reason: "tooManyConnections", code: 4429, until: nil)), "登录设备过多，当前设备已下线")
        XCTAssertEqual(fatalText(.kicked(reason: "suspended", code: 4012, until: .permanent)), "账号已被封禁")
        XCTAssertEqual(fatalText(.kicked(reason: "xyz", code: 4012, until: nil)), "账号已被下线")
        XCTAssertEqual(fatalText(.closed(code: 4010, reason: "")), "登录已失效，请重新登录")
        XCTAssertEqual(fatalText(.closed(code: 4011, reason: "")), "登录已过期，请重新登录")
        XCTAssertEqual(fatalText(.closed(code: 4429, reason: "")), "登录设备过多，当前设备已下线")
        let ts: Int64 = 1_800_000_000_000
        XCTAssertEqual(
            fatalText(.kicked(reason: "suspended", code: 4012, until: .at(ts))), "账号已被封禁，解封时间：\(formatDateTime(ts))")
    }

    func testMuteAndLoginCopy() {
        XCTAssertEqual(mutedText(.permanent), "你已被禁言")  // AC-UI-41-5
        let ts: Int64 = 1_800_000_000_000
        XCTAssertEqual(mutedText(.at(ts)), "你已被禁言，解除时间：\(formatMonthDayTime(ts))")
        // AC-UI-43-2, AC-UI-03-4, FE-010
        let banned = Data(#"{"code":4034,"details":{"bannedUntil":null}}"#.utf8)
        XCTAssertEqual(DemoLoginService.outcome(status: 403, data: banned), .failure("账号已被封禁"))
        let until = Data(#"{"code":4034,"details":{"bannedUntil":1800000000000}}"#.utf8)
        XCTAssertEqual(
            DemoLoginService.outcome(status: 403, data: until), .failure("账号已被封禁，解封时间：\(formatDateTime(1_800_000_000_000))"))
        XCTAssertEqual(DemoLoginService.outcome(status: 404, data: Data()), .failure("登录服务未开启"))
        XCTAssertEqual(
            DemoLoginService.outcome(status: 200, data: Data(#"{"userId":"a","token":"t"}"#.utf8)),
            .success(Session(userId: "a", token: "t")))
        XCTAssertEqual(
            DemoLoginService.outcome(status: 500, data: Data(#"{"msg":"secret detail"}"#.utf8)), .failure("服务异常，请稍后重试"))
    }

    func testLoginNetworkFailure() async {
        // AC-UI-03-5: nothing listens on this port.
        let out = await DemoLoginService(server: URL(string: "http://127.0.0.1:9")).login(username: "a", nickname: "")
        XCTAssertEqual(out, .failure("网络异常，请稍后重试"))
    }
}

@MainActor
final class TimeTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func ms(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Int64 {
        Int64(cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!.timeIntervalSince1970 * 1000)
    }

    func testFormats() {
        let now = Date(timeIntervalSince1970: TimeInterval(ms(2026, 11, 5, 12, 0)) / 1000)
        XCTAssertEqual(formatTime(ms(2026, 11, 5, 9, 5), now: now, calendar: cal), "09:05")
        XCTAssertEqual(formatTime(ms(2026, 11, 4, 23, 59), now: now, calendar: cal), "昨天 23:59")
        XCTAssertEqual(formatTime(ms(2026, 1, 2, 3, 4), now: now, calendar: cal), "01-02 03:04")
        XCTAssertEqual(formatTime(ms(2025, 12, 31, 8, 0), now: now, calendar: cal), "2025-12-31 08:00")
        XCTAssertEqual(formatDateTime(ms(2027, 2, 3, 4, 5), calendar: cal), "2027-02-03 04:05")
    }

    func testDivider() {
        XCTAssertTrue(needsDivider(previous: nil, ts: 0))
        XCTAssertFalse(needsDivider(previous: 0, ts: 5 * 60 * 1000))
        XCTAssertTrue(needsDivider(previous: 0, ts: 5 * 60 * 1000 + 1))
    }
}

@MainActor
final class RouteTests: XCTestCase {
    private func dest(_ s: String) -> Destination { parseDeepLink(URL(string: s)!) }

    func testKnownRoutes() {
        XCTAssertEqual(dest("tianting://chat/c2c%3Aalice%3Abob").path, [.chat("c2c:alice:bob")])
        XCTAssertEqual(dest("tianting://chat/group%3Ag1/info").path, [.chat("group:g1"), .chatInfo("group:g1")])
        XCTAssertEqual(
            dest("tianting://chat/group%3Ag1/members").path,
            [.chat("group:g1"), .chatInfo("group:g1"), .members("group:g1", .view)])
        XCTAssertEqual(dest("tianting://contacts").tab, .contacts)
        XCTAssertEqual(dest("tianting://contacts/requests").path, [.requests])
        XCTAssertEqual(dest("tianting://groups/new").path, [.groupNew])
        XCTAssertEqual(dest("tianting://me/settings/blocks").path, [.settings, .blocks])
        XCTAssertEqual(dest("tianting://user/bob").path, [.user("bob", UserContext())])
        XCTAssertEqual(
            dest("tianting://contacts/apply/bob").path, [.apply("bob", UserContext(source: .other))])
    }

    /// AC-UI-01-7 through the 3.6 table.
    func testEverythingElseGoesHome() {
        for s in [
            "tianting://evil.com", "tianting://evil.com/x", "tianting://not-a-route", "tianting://login",
            "tianting://chat", "tianting://chat/", "tianting://chat//x", "tianting://chat/a/b/c", "tianting://me/nope",
            "tianting://chat/c2c:alice:bob/notice", "tianting://chat/c2c%3Aa%3Ab/members",
            "https://evil.com/chat/x", "tianting://user:pw@chat/x", "tianting://chat:80/x", "tianting:///",
            "tianting://chat/%2F%2Fevil",
        ] {
            let d = dest(s)
            if s == "tianting://chat/%2F%2Fevil" {
                // An encoded id stays one segment; the chat page's strict parsing rejects it.
                XCTAssertEqual(d.path, [.chat("//evil")], s)
            } else {
                XCTAssertEqual(d, .home, s)
            }
        }
    }
}

@MainActor
final class ChatLogicTests: XCTestCase {
    func testBlockCopy() {
        // AC-UI-33-12
        let snap = snapshot
        XCTAssertEqual(chatBlock(snapshot: snap("dissolved"), probe: .idle)?.bar, "群聊已解散")
        XCTAssertEqual(chatBlock(snapshot: snap("dissolved"), probe: .idle)?.tip, "群聊已解散")
        XCTAssertEqual(chatBlock(snapshot: snap("left"), probe: .idle)?.bar, "你已退出该群聊")
        XCTAssertEqual(chatBlock(snapshot: snap("xyz"), probe: .idle)?.bar, "你已不在该群，无法发送消息")
        XCTAssertEqual(chatBlock(snapshot: snap(nil), probe: .idle)?.tip, "你已不在该群")
        XCTAssertEqual(chatBlock(snapshot: nil, probe: .notFound)?.bar, "群聊不存在或已解散")
        XCTAssertEqual(chatBlock(snapshot: nil, probe: .notMember)?.bar, "你已不在该群，无法发送消息")
        XCTAssertNil(chatBlock(snapshot: nil, probe: .loading))  // AC-UI-33-10: nothing until the server answers.
        XCTAssertNil(chatBlock(snapshot: nil, probe: .idle))
    }

    func testRowsDividers() {
        let rows = chatRows([message("a", ts: 0), message("b", ts: 1000), message("c", ts: 1000 + 6 * 60 * 1000)])
        XCTAssertEqual(rows.map(\.id), ["d-a", "a", "b", "d-c", "c"])
    }

    func testPermissionTipsKeepLastOfAdjacent() {
        // AC-UI-31-4
        let msgs = [message("a", status: .failed), message("b", status: .failed), message("c", status: .failed)]
        XCTAssertEqual(permissionTips(msgs, tips: ["a": 4035, "b": 4035, "c": 4035]), ["c": 4035])
        XCTAssertEqual(permissionTips(msgs, tips: ["a": 4035, "b": 4036]), ["a": 4035, "b": 4036])
        // A resend that succeeded drops its tip.
        XCTAssertEqual(permissionTips([message("a", status: .sent)], tips: ["a": 4035]), [:])
        XCTAssertEqual(permissionTips(msgs, tips: nil), [:])
    }

    func testSummaries() {
        let name = { (u: String) in u == "bob" ? "阿博" : u }
        let last = { (from: String, type: String, text: String?, deleted: Bool?) in
            LastMsg(msgId: "m", from: from, type: type, text: text, ts: 1, deleted: deleted)
        }
        // AC-UI-04-1, 04-2, 04-3, 04-4, 40-6, 42-2
        XCTAssertEqual(
            conversationSummary(conversation(.group, last: last("bob", "text", "晚上好", nil)), me: "alice", senderName: name), "阿博: 晚上好")
        XCTAssertEqual(
            conversationSummary(conversation(.group, last: last("alice", "text", "收到", nil)), me: "alice", senderName: name), "收到")
        XCTAssertEqual(
            conversationSummary(conversation(.c2c, last: last("bob", "text", "你好", nil)), me: "alice", senderName: name), "你好")
        XCTAssertEqual(conversationSummary(conversation(.group, last: nil), me: "alice", senderName: name), "")
        XCTAssertEqual(
            conversationSummary(conversation(.c2c, last: last("bob", "custom", nil, nil)), me: "alice", senderName: name),
            "[暂不支持的消息]")
        XCTAssertEqual(
            conversationSummary(conversation(.group, last: last("bob", "tip", "bob 邀请 carol", nil)), me: "alice", senderName: name),
            "bob 邀请 carol")
        XCTAssertEqual(
            conversationSummary(conversation(.group, last: last("bob", "text", nil, true)), me: "alice", senderName: name),
            "该消息已被删除")
    }

    func testOverLimitCount() {
        // AC-UI-10-4, C-27
        XCTAssertEqual(overLimitCount(String(repeating: "字", count: 5003)), 3)
        XCTAssertEqual(overLimitCount(String(repeating: "字", count: 5000)), 0)
        XCTAssertEqual(overLimitCount(String(repeating: "😀", count: 5001)), 1)
    }

    func testStatusValue() {
        XCTAssertEqual(messageStatusValue(.queued), "排队中")
        XCTAssertEqual(messageStatusValue(.failed), "发送失败")
    }

    func testEmojiList() {
        // AC-UI-11-4
        XCTAssertGreaterThanOrEqual(emojiList.count, 80)
        for e in emojiList {
            XCTAssertEqual(e.unicodeScalars.count, 1, e)
            XCTAssertLessThanOrEqual(e.unicodeScalars.first!.value, 0x1FAFF)
            XCTAssertNotEqual(e.unicodeScalars.first!.value, 0x200D)
        }
    }

    func testInsertAtCaret() {
        // AC-UI-11-1: "你好|世界".
        let r = insertText("😀", into: "你好世界", range: NSRange(location: 2, length: 0))
        XCTAssertEqual(r.text, "你好😀世界")
        XCTAssertEqual(r.caret, NSRange(location: 4, length: 0))
        // A selection is replaced, an out-of-range caret clamps.
        XCTAssertEqual(insertText("x", into: "abc", range: NSRange(location: 1, length: 1)).text, "axc")
        XCTAssertEqual(insertText("x", into: "abc", range: NSRange(location: 9, length: 0)).text, "abcx")
    }
}

@MainActor
final class SocialLogicTests: XCTestCase {
    func testCanChat() {
        // F-UI-14 rule 3 table, AC-UI-14-7
        XCTAssertTrue(canChat(relation: .friend, isFriend: true, mode: .friends, official: false))
        XCTAssertTrue(canChat(relation: .none, isFriend: false, mode: .open, official: false))
        XCTAssertFalse(canChat(relation: .none, isFriend: false, mode: .friends, official: false))
        XCTAssertTrue(canChat(relation: .none, isFriend: false, mode: .friends, official: true))
        XCTAssertFalse(canChat(relation: .blocked, isFriend: false, mode: .friends, official: false))
        XCTAssertTrue(canChat(relation: .blocked, isFriend: true, mode: .friends, official: false))
        XCTAssertFalse(canChat(relation: .pendingIn, isFriend: false, mode: .friends, official: false))
        XCTAssertTrue(canChat(relation: .pendingOut, isFriend: false, mode: .open, official: false))
        XCTAssertFalse(canChat(relation: .`self`, isFriend: false, mode: .open, official: false))
    }

    func testValidUserId() {
        XCTAssertTrue(isValidUserId("a-b_C9"))
        XCTAssertFalse(isValidUserId("a b"))
        XCTAssertFalse(isValidUserId(""))
        XCTAssertFalse(isValidUserId(String(repeating: "a", count: 65)))
        XCTAssertFalse(isValidUserId("张三"))
    }

    func testBadge() {
        XCTAssertEqual(badgeText(5), "5")
        XCTAssertEqual(badgeText(99), "99")
        XCTAssertEqual(badgeText(120), "99+")  // AC-UI-04-6
    }

    func testStartChatWarning() {
        // AC-UI-05-3, AC-UI-05-6
        XCTAssertTrue(startChatNeedsWarning(target: "c", me: "a", mode: .friends, relation: .none))
        XCTAssertFalse(startChatNeedsWarning(target: "b", me: "a", mode: .friends, relation: .friend))
        XCTAssertFalse(startChatNeedsWarning(target: "a", me: "a", mode: .friends, relation: .`self`))
        XCTAssertFalse(startChatNeedsWarning(target: "c", me: "a", mode: .open, relation: .none))
    }

    func testHttpsOnlyAvatars() {
        // AC-UI-21-4, AC-UI-21-5
        XCTAssertNotNil(httpsURL("https://x.test/a.png"))
        XCTAssertNil(httpsURL("http://x.test/a.png"))
        XCTAssertNil(httpsURL(""))
        XCTAssertNil(httpsURL(nil))
        XCTAssertNil(httpsURL("file:///etc/passwd"))
    }

    func testAvatarVectors() throws {
        // AC-UI-21-2
        let data = try Data(contentsOf: sdkProtocolDir.appendingPathComponent("vectors/avatar.json"))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let colors = root["colors"] as! [[String: Any]]
        XCTAssertFalse(colors.isEmpty)
        XCTAssertEqual(Tokens.avatar.count, 8)
        for c in colors {
            XCTAssertEqual(avatarColorIndex(c["id"] as! String), c["index"] as! Int)
        }
        for c in root["initials"] as! [[String: Any]] {
            XCTAssertEqual(avatarInitial(c["name"] as! String), c["initial"] as! String)
        }
    }

    func testPinyinVectorsAndOrder() throws {
        // AC-UI-13-9, AC-UI-13-3, AC-UI-32-1
        let data = try Data(contentsOf: sdkProtocolDir.appendingPathComponent("vectors/pinyin-groups.json"))
        let root = try JSONSerialization.jsonObject(with: data)
        let cases = (root as? [[String: Any]]) ?? ((root as? [String: Any])?["cases"] as? [[String: Any]]) ?? []
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            guard let name = c["name"] as? String, let group = c["group"] as? String else { continue }
            XCTAssertEqual(pinyinGroup(name), group, name)
        }
        let sections = groupByPinyin(["123", "😀abc", "bob", "alice", "张三"], name: { $0 }, id: { $0 })
        XCTAssertEqual(sections.map(\.letter), ["A", "B", "Z", "#"])
        XCTAssertEqual(sections.last?.items, ["123", "😀abc"])
        XCTAssertTrue(nameLess("Alpha", "周末球局"))
        XCTAssertFalse(nameLess("周末球局", "Alpha"))
        XCTAssertTrue(nameLess("李四", "张三"))
    }
}

@MainActor
final class GroupLogicTests: XCTestCase {
    func testPermissionsByRole() {
        // AC-UI-36-1
        let member = GroupPermissions(role: .member, managed: false, owner: "o")
        XCTAssertTrue(member.canInvite)
        XCTAssertFalse(member.canManage)
        XCTAssertFalse(member.isOwner)
        XCTAssertFalse(member.canDissolve)
        XCTAssertEqual(member.leaveText, "退出后，将不再接收此群聊消息")
        // AC-UI-36-2
        let admin = GroupPermissions(role: .admin, managed: false, owner: "o")
        XCTAssertTrue(admin.canManage)
        XCTAssertFalse(admin.isOwner)
        XCTAssertFalse(admin.canDissolve)
        // AC-UI-36-3
        let owner = GroupPermissions(role: .owner, managed: false, owner: "me")
        XCTAssertTrue(owner.canManage && owner.isOwner && owner.canDissolve && owner.canInvite)
        XCTAssertEqual(owner.leaveText, "你是群主，退出后群主将自动转让给其他成员")
        let hostedOwner = GroupPermissions(role: .owner, managed: true, owner: "me")
        XCTAssertFalse(hostedOwner.canDissolve)
        XCTAssertTrue(hostedOwner.isOwner)
        // AC-UI-36-4
        let hosted = GroupPermissions(role: .member, managed: true, owner: "")
        XCTAssertFalse(hosted.canInvite)
        XCTAssertFalse(hosted.canManage)
    }

    func testMemberModes() {
        XCTAssertEqual(allowedMemberMode(.kick, role: .member), .view)
        XCTAssertEqual(allowedMemberMode(.kick, role: .admin), .kick)
        XCTAssertEqual(allowedMemberMode(.admin, role: .admin), .view)
        XCTAssertEqual(allowedMemberMode(.transfer, role: .owner), .transfer)
        XCTAssertEqual(allowedMemberMode(.kick, role: nil), .view)
        // AC-UI-38-3
        XCTAssertFalse(memberSelectable(member: .owner, mode: .kick, myRole: .admin))
        XCTAssertFalse(memberSelectable(member: .admin, mode: .kick, myRole: .admin))
        XCTAssertTrue(memberSelectable(member: .member, mode: .kick, myRole: .admin))
        XCTAssertTrue(memberSelectable(member: .admin, mode: .kick, myRole: .owner))
        XCTAssertFalse(memberSelectable(member: .owner, mode: .transfer, myRole: .owner))
    }

    func testInviteText() {
        // AC-UI-39-1, 39-2, F-UI-39 rule 3
        let names = { (u: String) in u }
        XCTAssertEqual(
            inviteResultText(GroupInviteResultFixture.make(added: ["a", "b"], failed: []), me: "m", name: names), "已邀请 2 人")
        XCTAssertEqual(
            inviteResultText(GroupInviteResultFixture.make(added: ["a"], failed: [("eve", 4035)]), me: "m", name: names),
            "已邀请 1 人；eve 不是你的好友，无法邀请")
        let many = inviteResultText(
            GroupInviteResultFixture.make(added: [], failed: (0..<5).map { ("u\($0)", 4035) }), me: "m", name: names)
        XCTAssertTrue(many.hasSuffix("另有 2 人邀请失败"))
        XCTAssertEqual(many.components(separatedBy: "不是你的好友").count - 1, 3)
        XCTAssertEqual(
            memberErrorText(code: 4135, userId: "m", cmd: "groupCreate", me: "m", name: names), "你加入的群聊已达上限")
    }

    func testGroupSort() throws {
        let decode = { (json: String) in try JSONDecoder().decode(MyGroup.self, from: Data(json.utf8)) }
        let a = try decode(#"{"groupId":"g2","name":"周末球局","memberCount":12,"joinedAt":1}"#)
        let b = try decode(#"{"groupId":"g1","name":"Alpha","memberCount":3,"joinedAt":1}"#)
        XCTAssertEqual(sortedGroups([a, b]).map(\.name), ["Alpha", "周末球局"])
    }

    func testTipCopyUsesLocalNames() {
        // AC-UI-40-1 to 40-4; copy lives in the SDK (vectors/social.json), this pins the app's use of it.
        let name = { (u: String) in u == "carol" ? "卡姐" : u }
        XCTAssertEqual(
            tipText(TipBody(kind: "joined", actor: "bob", targets: ["carol", "dave"]), me: "me", nameOf: name),
            "bob 邀请 卡姐、dave 加入了群聊")
        XCTAssertEqual(tipText(TipBody(kind: "ownerChanged", actor: "", targets: []), me: "me", nameOf: name), "群主已退出群聊")
        XCTAssertEqual(tipText(TipBody(kind: "created", actor: "me", targets: []), me: "me", nameOf: name), "你创建了群聊")
        XCTAssertEqual(tipText(TipBody(kind: "futureKind", actor: "bob", targets: []), me: "me", nameOf: name), "[群通知]")
    }
}

enum GroupInviteResultFixture {
    static func make(added: [String], failed: [(String, Int)]) -> GroupInviteResult {
        let json: [String: Any] = ["added": added, "failed": failed.map { ["userId": $0.0, "code": $0.1] }]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(GroupInviteResult.self, from: data)
    }
}

@MainActor
final class PrefsAndSessionTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "tt.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testThemePrefStoredUnderUiKey() {
        // AC-UI-22-5, AC-UI-90-2
        let d = defaults()
        let prefs = UIPrefs(defaults: d)
        XCTAssertEqual(ThemeController(prefs: prefs).pref, .system)
        ThemeController(prefs: prefs).set(.light)
        XCTAssertEqual(d.string(forKey: "ui.theme"), "light")
        XCTAssertEqual(ThemeController(prefs: prefs).pref, .light)
        prefs.set("ui.theme", "garbage")
        XCTAssertEqual(ThemeController(prefs: prefs).pref, .system)
    }

    func testDraftsWhitespaceRemoves() {
        // AC-UI-24-3
        let d = DraftStore()
        d.put("c", "明天见")
        XCTAssertEqual(d.draft("c"), "明天见")
        d.put("c", "  \n")
        XCTAssertNil(d.draft("c"))
    }

    func testTextLength() {
        XCTAssertEqual(textLength("  😀ab "), 3)
        XCTAssertEqual(textLength(String(repeating: "字", count: 33)), 33)
    }

    func testConfigWebSocketURL() {
        XCTAssertEqual(AppConfig(server: URL(string: "http://localhost:8080"), demoLogin: true).webSocketURL, "ws://localhost:8080/ws")
        XCTAssertEqual(AppConfig(server: URL(string: "https://im.test"), demoLogin: true).webSocketURL, "wss://im.test/ws")
        XCTAssertNil(AppConfig(server: nil, demoLogin: false).webSocketURL)
    }
}
