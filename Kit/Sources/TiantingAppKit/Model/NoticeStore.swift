import Foundation
import Observation
import TiantingIM

// System notices (PRD-ui F-UI-44, PRD-live F-PUSH-12): only type=notice is shown. The list lives in memory, so after a
// restart it only has what arrived since (L-4, accepted, stated on the page). UserDefaults holds one number per user:
// `ui.noticeSeen.{userId}`, the lastSeenSeq.

public func noticeSeenKey(_ userId: String) -> String { "ui.noticeSeen.\(userId)" }

/// The first 50 code points, so an emoji is not cut in half.
public func noticeBannerText(_ text: String) -> String {
    var head = String.UnicodeScalarView()
    head.append(contentsOf: text.unicodeScalars.prefix(50))
    return "系统通知：\(String(head))"
}

public struct Notice: Identifiable, Equatable, Sendable {
    public let pushId: String
    public let text: String
    public let ts: Int64
    public let pushSeq: Int64?

    public var id: String { pushId }
}

@MainActor
@Observable
public final class NoticeStore {
    public struct Banner: Equatable, Sendable {
        public let text: String
        /// Grows with each notice: a new one replaces the old and restarts the timer.
        public let n: Int
    }

    private static let listMax = 100

    public private(set) var list: [Notice] = []
    public private(set) var unseen = 0
    public private(set) var banner: Banner?
    @ObservationIgnored public var bannerDuration: Duration = .seconds(5)

    @ObservationIgnored private let client: IMClient
    @ObservationIgnored private let userId: String
    @ObservationIgnored private let prefs: UIPrefs
    /// The SDK is at-least-once: the app is idempotent on pushId (PRD-live 4.8).
    @ObservationIgnored private var seenIds = Set<String>()
    @ObservationIgnored private var maxSeq: Int64 = 0  // The highest pushSeq of the notices this instance received.
    @ObservationIgnored private var pages = 0  // Open system notice pages.
    @ObservationIgnored private var bannerN = 0
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var subscriptions: [IMSubscription] = []

    public init(client: IMClient, userId: String, prefs: UIPrefs) {
        self.client = client
        self.userId = userId
        self.prefs = prefs
    }

    /// Before `connect`: the SDK only catches up when a subscriber exists (PRD-live C12).
    public func attach() {
        guard subscriptions.isEmpty else { return }
        subscriptions = [
            client.onPush { [weak self] in self?.onPush($0) },
            client.onPushSynced { [weak self] in self?.onSynced($0) },
        ]
    }

    public func detach() {
        for s in subscriptions { s.cancel() }
        subscriptions = []
        bannerTask?.cancel()
        bannerTask = nil
    }

    /// Opening the page clears the count and moves lastSeenSeq up to what was received (rules 3, 4).
    public func enterPage() {
        pages += 1
        raiseLastSeen()
        unseen = 0
    }

    public func leavePage() {
        pages = max(0, pages - 1)
    }

    public func dismissBanner() {
        bannerTask?.cancel()
        bannerTask = nil
        banner = nil
    }

    private func onPush(_ p: Push) {
        guard p.type == "notice" else {
            TTLog.event("push.ignored")  // Other types are for the integrator's code; data may hold an account.
            return
        }
        guard let text = p.data["text"]?.stringValue else {
            TTLog.event("push.noticeWithoutText")
            return
        }
        guard seenIds.insert(p.pushId).inserted else { return }
        if let seq = p.pushSeq, seq > maxSeq { maxSeq = seq }

        var next = list
        next.append(Notice(pushId: p.pushId, text: text, ts: p.ts, pushSeq: p.pushSeq))
        next.sort { a, b in a.ts != b.ts ? a.ts > b.ts : (a.pushSeq ?? -1) > (b.pushSeq ?? -1) }
        if next.count > Self.listMax { next.removeLast(next.count - Self.listMax) }  // Not shown, still counted.
        list = next

        if pages > 0 {
            raiseLastSeen()
        } else if !p.replayed {
            unseen += 1
        } else if let seq = p.pushSeq, let last = readLastSeen(), seq > last {
            unseen += 1
        }

        guard !p.replayed else { return }
        bannerN += 1
        banner = Banner(text: noticeBannerText(text), n: bannerN)
        bannerTask?.cancel()
        let n = bannerN
        let duration = bannerDuration
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.banner?.n == n else { return }
            self.banner = nil
        }
    }

    /// One catch-up round ended: sets the baseline (L-18's accepted loss: this round's replay is not counted), and follows
    /// the sequence back after a server restore (rule 4).
    private func onSynced(_ latestSeq: Int64) {
        if let last = readLastSeen(), last <= latestSeq { return }
        prefs.set(noticeSeenKey(userId), String(latestSeq))
    }

    private func readLastSeen() -> Int64? {
        guard let raw = prefs.get(noticeSeenKey(userId)), !raw.isEmpty, raw.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int64(raw)
    }

    private func raiseLastSeen() {
        guard maxSeq > 0 else { return }
        if let last = readLastSeen(), last >= maxSeq { return }
        prefs.set(noticeSeenKey(userId), String(maxSeq))
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
