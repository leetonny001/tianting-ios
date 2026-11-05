import TiantingIM
import XCTest

/// M4 group management against the real server.
final class GroupE2ETests: E2ECase {
    func testCreateGroupAndManage() async throws {
        let (me, bob, carol, dave) = (uid("a"), uid("b"), uid("c"), uid("d"))
        let peerBob = try await peer(bob)
        let peerDave = try await peer(dave)
        try await importUsers([me, carol])
        for o in [bob, carol, dave] { try await makeFriends(me, o) }
        try await launchAndLogin(me)

        // AC-UI-05-8
        try await tap("plus-button")
        let items = ["发起群聊", "添加朋友", "发起单聊"].map { app.buttons[$0].firstMatch }
        try await see(items[0])
        XCTAssertLessThan(items[0].frame.minY, items[1].frame.minY)
        XCTAssertLessThan(items[1].frame.minY, items[2].frame.minY)
        items[0].tap()

        // AC-UI-35-2, AC-UI-35-3
        try await see("pick-done")
        let row = { (u: String) in self.el("pick-row", labelContains: u) }
        try await see(row(bob))
        row(bob).tap()
        XCTAssertFalse(el("pick-done").isEnabled, "one person is not enough")
        try await type(String(carol.prefix(1)).uppercased() + carol.dropFirst(), into: "pick-search")
        try await see(row(carol))
        try await gone(row(dave))
        row(carol).tap()
        try await clearAndType("", into: "pick-search")
        try await see(row(dave))
        row(dave).tap()
        XCTAssertTrue(el("pick-done").label.contains("3"))

        // AC-UI-35-1
        try await tap("pick-done")
        try await see("group-name-sheet")
        try await type("球队", into: "group-name-input")
        try await tap("group-create") { !self.el("group-name-sheet").exists }
        try await see("chat-title")
        try await until("title") { self.label("chat-title") == "球队（4）" }
        try await see(el("tip", labelContains: "你创建了群聊"))
        let tips = app.descendants(matching: .any).matching(identifier: "tip")
        XCTAssertGreaterThanOrEqual(tips.count, 1)

        var convId = ""
        try await until("peer has the group") {
            if let c = peerBob.conversations().first(where: { $0.type == .group }) {
                convId = c.convId
                return true
            }
            return false
        }
        let gid = String(convId.dropFirst("group:".count))

        // AC-UI-36-3: owner sees all.
        try await tap("chat-more")
        try await see("member-grid")
        for id in ["grid-invite", "grid-kick", "manage-admin", "manage-transfer", "group-leave", "group-dissolve", "group-notice"] {
            try await see(id)
        }
        capture("group-settings-owner")

        // AC-UI-36-5: rename shows everywhere.
        try await tap("group-name")
        try await see("rename-sheet")
        try await clearAndType("周六球局", into: "rename-input")
        try await tap("rename-save") { !self.el("rename-sheet").exists }
        try await until("peer sees rename") {
            peerBob.conversations().first { $0.convId == convId }?.name == "周六球局"
        }

        // AC-UI-37-1: notice.
        try await tap("group-notice")
        try await see("notice-edit")
        try await tap("notice-edit")
        try await type("周六 9 点集合", into: "notice-input")
        try await see("notice-count")
        XCTAssertEqual(label("notice-count"), "已输入 \("周六 9 点集合".unicodeScalars.count) / 1000")
        try await tap("notice-save") { self.el("notice-text").exists }
        try await see("notice-text")
        XCTAssertEqual(label("notice-text"), "周六 9 点集合")
        XCTAssertTrue(el("notice-meta").exists)
        try await back()
        try await see("group-notice-preview")

        // AC-UI-38-4: set an admin.
        try await tap("manage-admin")
        try await see(el("member-row", labelContains: dave))
        el("member-row", labelContains: dave).tap()
        try await see(el("member-row", labelContains: "管理员"))
        try await back()

        // AC-UI-38-2: kick.
        try await tap("grid-kick")
        try await see(el("member-row", labelContains: carol))
        el("member-row", labelContains: carol).tap()
        try await tap("kick-submit")
        try await see("kick-confirm")
        XCTAssertEqual(label("dialog-text"), "确定将 1 人移出群聊？")
        try await tap("dialog-ok")
        try await gone(el("member-row", labelContains: carol))
        try await back()

        // AC-UI-39: invite; a member shows "已在群里" and cannot be picked (AC-UI-39-3).
        try await tap("grid-invite")
        try await see(row(carol))
        try await see(row(bob))
        try await until("bob joined") { row(bob).label.contains("已在群里") }
        XCTAssertFalse(row(bob).isEnabled)
        row(carol).tap()
        try await tap("pick-done")
        try await see("toast")
        XCTAssertEqual(label("toast"), "已邀请 1 人")
        try await see("member-grid")

        // AC-UI-38-1 shape: first in the list is the owner.
        try await tap("all-members")
        try await see("member-role")
        XCTAssertTrue(all("member-row").element(boundBy: 0).label.contains("群主"))
        try await back()

        // AC-UI-38-5: transfer.
        try await tap("manage-transfer")
        try await see(el("member-row", labelContains: bob))
        el("member-row", labelContains: bob).tap()
        try await see("transfer-confirm")
        try await tap("dialog-ok")
        try await until("transferred") {
            (try? self.el("manage-admin").exists) == false || peerBob.conversations().first { $0.convId == convId }?.myRole == .owner
        }
        try await back()
        try await see("group-leave")
        try await staysGone(el("group-dissolve"))

        // AC-UI-36-6 text for a member; leaving returns to the list.
        try await tap("group-leave")
        try await see("leave-confirm")
        XCTAssertEqual(label("dialog-text"), "退出后，将不再接收此群聊消息")
        try await tap("dialog-ok")
        try await see("tab-chats")
        try await gone(conv("周六球局"))
        _ = (peerDave, gid)
    }

    func testRolesSeeTheirEntries() async throws {
        // AC-UI-36-1, 36-2, 36-4, AC-UI-37-2
        let (me, owner) = (uid("a"), uid("o"))
        let peerOwner = try await peer(owner)
        let third = uid("t")
        try await importUsers([me, third])
        try await makeFriends(owner, me)
        try await makeFriends(owner, third)
        try await until("friends synced") { peerOwner.friends().count == 2 }
        let created = try await peerOwner.createGroup(name: "自建群", members: [me, third])
        try await launchAndLogin(me)
        try await see(conv("自建群"))
        conv("自建群").tap()
        try await see(el("tip", labelContains: "创建了群聊"))
        try await tap("chat-more")
        try await see("member-grid")

        // Member.
        try await see("grid-invite")
        for id in ["grid-kick", "manage-admin", "manage-transfer", "group-dissolve"] {
            XCTAssertFalse(el(id).exists, id)
        }
        XCTAssertNotEqual(el("group-name").value as? String, "可修改")
        try await tap("group-notice")
        try await see("notice-readonly")
        XCTAssertEqual(label("notice-readonly"), "仅群主和管理员可编辑")
        XCTAssertFalse(el("notice-edit").exists)
        try await back()

        // Promoted to admin: "−" appears, the name is editable; no owner entries (AC-UI-36-2, AC-UI-38-4).
        try await peerOwner.setGroupAdmin(created.groupId, userId: me, admin: true)
        try await see("grid-kick")
        try await until("editable") { (self.el("group-name").value as? String) == "可修改" }
        for id in ["manage-admin", "manage-transfer", "group-dissolve"] {
            XCTAssertFalse(el(id).exists, id)
        }

        // AC-UI-38-3: the owner cannot be picked.
        try await tap("grid-kick")
        try await see(el("member-row", labelContains: owner))
        XCTAssertFalse(el("member-row", labelContains: owner).isEnabled)
        XCTAssertTrue(el("member-row", labelContains: third).isEnabled)
        try await back()
        try await back()

        // AC-UI-36-7: dissolved by the owner while on the chat page (AC-UI-33-7).
        try await peerOwner.dissolveGroup(created.groupId)
        try await see("chat-blocked-tip", timeout: 3)
        XCTAssertEqual(label("composer-disabled"), "群聊已解散")
    }

    func testHostedGroupWithoutOwner() async throws {
        // AC-UI-36-4
        let me = uid("a")
        let bob = uid("b")
        try await importUsers([me, bob])
        try await hostedGroup(name: "托管群", members: [me, bob])
        try await launchAndLogin(me)
        try await see(conv("托管群"))
        conv("托管群").tap()
        try await tap("chat-more")
        try await see("member-grid")
        try await see("group-leave")
        for id in ["grid-invite", "grid-kick", "manage-admin", "manage-transfer", "group-dissolve"] {
            XCTAssertFalse(el(id).exists, id)
        }
    }

    func testHostedOwnerCannotDissolve() async throws {
        // AC-UI-36-3
        let me = uid("a")
        let bob = uid("b")
        try await importUsers([me, bob])
        try await hostedGroup(name: "有主托管群", members: [me, bob], owner: me)
        try await launchAndLogin(me)
        try await see(conv("有主托管群"))
        conv("有主托管群").tap()
        try await tap("chat-more")
        try await see("manage-admin")
        try await see("grid-invite")
        XCTAssertFalse(el("group-dissolve").exists)
    }
}
