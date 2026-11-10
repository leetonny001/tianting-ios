import Foundation
import TiantingIM
import XCTest

/// FE-672: C4 across H5, Android and iOS against one im-server (recall, quote, @). The platforms cannot run at the same time,
/// so each first sends through its own UI (`testXP4a_send`), and later receives through its own UI (`testXP4b_receive`).
///
/// The shared contract (tianting-web's xp-c4.spec.ts and tianting-android's CrossPlatformC4E2e copy this):
/// - Run id R (`TT_E2E_XP`). Users `xp{R}h5`, `xp{R}android`, `xp{R}ios`, each nickname the userId. Each sender p has two
///   groups with all three, owned by p: `xp{R}m{p}` "C4引用提及-{p}" and `xp{R}r{p}` "C4撤回-{p}". others(p) is h5, android,
///   ios without p, in that order: q1, q2.
/// - The coordinating script puts in: q1 says "XP4-q-{q1}@{p}" in the m group; q1, then q2, say "XP4-r-{q}@{p}" in the r group
///   (q2's is the r group's last message).
/// - Send (p): (1) to each q in a one-to-one chat "XP4-{p}>{q}-撤回原文", then long press and recall it; (2) in the m group
///   quote "XP4-q-{q1}@{p}" and reply "XP4-{p}-引用回复"; then type @ and pick q1, @ and pick q2, add "XP4-{p}-提及" and send;
///   (3) in the r group, as the owner, recall q2's and q1's messages.
/// - Receive (`TT_E2E_XP_FROM`, default the other two): the one-to-one chat has "对方撤回了一条消息" and no original text, and
///   the list summary is a recall line; the m group's row has "[有人@我]", the reply's quote reads "{q1}: XP4-q-{q1}@{p}" and the
///   mention is marked as mentioning me; the r group: my message "{p}撤回了你的一条消息", the other "{p}撤回了一条成员消息", the
///   list summary by the last one.
/// Without `TT_E2E_XP` these tests skip. Local results on the simulator. Quoted text and @ content are asserted, never printed.
@MainActor
final class CrossPlatformC4E2ETests: E2ECase {
    static let me = "ios"
    static let platforms = ["h5", "android", "ios"]

    var run: String { Self.env("TT_E2E_XP") ?? "" }
    func user(_ p: String) -> String { "xp\(run)\(p)" }
    var me: String { user(Self.me) }
    func others(_ p: String) -> [String] { Self.platforms.filter { $0 != p } }
    func mGroup(_ p: String) -> String { "group:xp\(run)m\(p)" }
    func rGroup(_ p: String) -> String { "group:xp\(run)r\(p)" }
    func recallText(_ p: String, _ q: String) -> String { "XP4-\(p)>\(q)-撤回原文" }
    func quoted(_ p: String) -> String { "XP4-q-\(others(p)[0])@\(p)" }
    func reply(_ p: String) -> String { "XP4-\(p)-引用回复" }
    func mention(_ p: String) -> String { "XP4-\(p)-提及" }
    func seed(_ q: String, _ p: String) -> String { "XP4-r-\(q)@\(p)" }

    override func setUp() async throws {
        try await super.setUp()
        guard !run.isEmpty else { throw XCTSkip("the cross-platform tests need TT_E2E_XP from the coordinating script") }
        let all = Self.platforms.map { user($0) }
        try await importUsers(all, nicknames: Dictionary(uniqueKeysWithValues: all.map { ($0, $0) }))
    }

    /// A list row by its name: the row reads "name，summary，…".
    func row(_ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'conv-item' AND label BEGINSWITH %@", name + "，")
        ).firstMatch
    }

    private func openRow(_ name: String) async throws {
        try await tapElement(row(name))
        try await see("chat-title")
    }

    func testXP4a_send() async throws {
        let check = try await peer(me)  // sdk-swift in the runner, the same user as the app
        launch()
        try await login(me)
        // (1) One-to-one recall.
        for q in others(Self.me) {
            try await startChat(with: user(q))
            try await send(recallText(Self.me, q))
            try await sent(recallText(Self.me, q))
            try await longPress(message(recallText(Self.me, q)))
            _ = try await menuShown()
            try await tapMenuItem("撤回")
            try await gone(message(recallText(Self.me, q)), timeout: 10)
            try await see(el("msg-recalled", labelContains: "你撤回了一条消息"))
            try await back()
        }
        // (2) The m group: quote q1's message; @ q1 and q2.
        let (q1, q2) = (others(Self.me)[0], others(Self.me)[1])
        try await openRow("C4引用提及-\(Self.me)")
        try await longPress(message(quoted(Self.me)))
        _ = try await menuShown()
        try await tapMenuItem("引用")
        try await see("quote-bar")
        XCTAssertEqual(label("quote-bar-text"), "引用：\(user(q1)): \(quoted(Self.me))")
        try await typeInComposer(reply(Self.me))
        try await tapSend()
        try await see(el("msg-quote", labelContains: quoted(Self.me)), timeout: 10)
        try await typeInComposer("@")
        try await pickMember(user(q1))
        try await typeInComposer("@")
        try await pickMember(user(q2))
        try await typeInComposer(mention(Self.me))
        XCTAssertEqual(composerText(), "@\(user(q1)) @\(user(q2)) \(mention(Self.me))")
        try await tapSend()
        let text = "@\(user(q1)) @\(user(q2)) \(mention(Self.me))"
        var got: Message?
        try await until("the mention on the server", timeout: 20) {
            got = check.messages(self.mGroup(Self.me)).first { $0.body.text == text && $0.seq != nil }
            return got != nil
        }
        XCTAssertEqual(Set(got?.body.mentions?.userIds ?? []), [user(q1), user(q2)])
        let r = check.messages(mGroup(Self.me)).first { $0.body.text == reply(Self.me) }
        XCTAssertEqual(r?.body.quote?.text, quoted(Self.me))
        try await back()
        // (3) The r group: the owner recalls two members' messages (q2's first, the last one).
        try await openRow("C4撤回-\(Self.me)")
        for q in [q2, q1] {
            try await longPress(message(seed(q, Self.me)))
            _ = try await menuShown()
            try await tapMenuItem("撤回")
            try await see(el("msg-recalled", labelContains: "你撤回了 \(user(q)) 的一条消息"), timeout: 10)
        }
        XCTAssertFalse(staticText(containing: "XP4-r-").exists, "no original text on the page")
        try await back()
        try await see(el("conv-item", labelContains: "你撤回了 \(user(q2)) 的一条消息"))
    }

    func testXP4b_receive() async throws {
        // run-e2e.sh passes an empty value when it is not set: empty means the other two.
        let given = Self.env("TT_E2E_XP_FROM") ?? ""
        let from = (given.isEmpty ? others(Self.me).joined(separator: ",") : given).split(separator: ",").map(String.init)
        XCTAssertFalse(from.isEmpty)
        let check = try await peer(me)
        launch()
        try await login(me)
        for p in from {
            let (q1, q2) = (others(p)[0], others(p)[1])
            // The list.
            let m = row("C4引用提及-\(p)")
            try await see(m, timeout: 30)
            XCTAssertTrue(m.label.contains("[有人@我]"), "the m group's row: \(m.label.count) chars")
            let last = q2 == Self.me ? "\(user(p))撤回了你的一条消息" : "\(user(p))撤回了一条成员消息"
            try await see(el("conv-item", labelContains: "C4撤回-\(p)，\(last)"), timeout: 15)
            let c2cRow = row(user(p))
            try await see(c2cRow, timeout: 15)
            XCTAssertTrue(c2cRow.label.contains("撤回了一条消息"), "the one-to-one row is a recall line")
            // The one-to-one chat.
            try await openRow(user(p))
            try await see(el("msg-recalled", labelContains: "对方撤回了一条消息"), timeout: 15)
            XCTAssertFalse(staticText(containing: recallText(p, Self.me)).exists, "no original text")
            XCTAssertFalse(message(recallText(p, Self.me)).exists)
            try await back()
            // The m group: quote and mention.
            try await openRow("C4引用提及-\(p)")
            try await see(el("msg-quote", labelContains: "\(user(q1)): \(quoted(p))"), timeout: 15)
            let mm = message(mention(p))
            try await see(mm, timeout: 15)
            XCTAssertTrue(mm.label.hasSuffix("，提到了你"), "marked as mentioning me")
            _ = try? await check.loadHistory(mGroup(p))
            let got = check.messages(mGroup(p)).first { $0.body.text?.hasSuffix(mention(p)) == true }
            XCTAssertTrue(got?.body.mentions?.userIds.contains(me) == true, "mentions has me")
            try await back()
            // The r group: rule 1a, row 3.
            try await openRow("C4撤回-\(p)")
            try await see(el("msg-recalled", labelContains: "\(user(p))撤回了你的一条消息"), timeout: 15)
            try await see(el("msg-recalled", labelContains: "\(user(p))撤回了一条成员消息"))
            XCTAssertFalse(staticText(containing: "XP4-r-").exists, "no original text")
            try await back()
        }
    }
}
