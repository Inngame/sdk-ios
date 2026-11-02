import Foundation
import Network
import StoreKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// In-app support chat. Configure once at launch, identify after login, then show `InngameChatView`.
///
/// ```swift
/// Inngame.configure(appKey: "app_…")
/// Inngame.identify(userId: user.id, name: user.name, email: user.email)
/// // SwiftUI
/// .sheet(isPresented: $help) { InngameChatView() }
/// ```
@MainActor
public final class Inngame: ObservableObject {
    public static let sdkVersion = "0.2.3"
    public static let shared = Inngame()

    @Published public private(set) var messages: [InngameMessage] = []
    @Published public private(set) var unreadCount = 0
    @Published public private(set) var user: InngameUser?
    @Published public private(set) var config: InngameRemoteConfig?
    @Published public private(set) var isTeamTyping = false
    @Published public private(set) var isBlocked = false
    @Published public private(set) var hasMore = false
    @Published public private(set) var isReady = false
    @Published public internal(set) var isChatVisible = false {
        didSet {
            guard isChatVisible else { return }
            if isUnavailable { if suspension.recheckOnOpen(now: Date()) { recheck() } } else { Task { await markRead() } }
        }
    }
    /// True while the studio's support is unavailable (its Inngame workspace is suspended): the chat says
    /// "Support is unavailable right now. Please try again later.", hides the composer and keeps unsent messages.
    /// The SDK asks again every 10 minutes while the chat is open and each time it opens, and comes back on its own.
    @Published public private(set) var isUnavailable = false
    @Published public var lastError: String?
    /// Set when a push or an automation asks to open the chat; bind it to your sheet.
    @Published public var wantsToOpen = false
    /// Messages the server hasn't accepted yet (no network…): kept on the device and sent again at the next launch or when the network is back.
    @Published public private(set) var pending: [InngamePendingMessage] = []

    private var api: APIClient?
    private var realtime: Realtime?
    private var context: [String: JSONValue] = [:]
    private var pendingIdentity: [String: Any]?
    private var startTask: Task<Void, Never>?
    private var typingReset: Task<Void, Never>?
    private var pushToken: (String, String)?
    private var delivering = Set<String>()
    private var network: NWPathMonitor?
    private var suspension = SuspensionClock()
    private var recheckLoop: Task<Void, Never>?

    // MARK: - Card handlers

    /// "offer" card tapped: the chat closes, then show your paywall or store page for this offer id.
    /// Without a handler the tap is reported to your team as failed.
    public static var onOffer: ((_ offerId: String?) -> Void)?
    /// "screen" card tapped: the chat closes, then navigate to this screen of your app (the card's screen id and value).
    public static var onScreen: ((_ screen: String?, _ value: String?) -> Void)?
    /// "restore" card tapped. Default (nil): StoreKit's `AppStore.sync()`. Set it to use your IAP library instead.
    public static var onRestorePurchases: (() -> Void)?
    /// "item" card claimed and confirmed by the server (once per card, even with several devices): refresh your UI.
    /// Credit the user on your server from the `item.claimed` webhook. Without a handler, item cards stay disabled.
    public static var onItemGranted: ((InngameItem) -> Void)?

    // MARK: - Static API

    public static func configure(appKey: String, baseURL: URL = URL(string: "https://app.inngame.app")!) { shared.configure(appKey: appKey, baseURL: baseURL) }
    /// Identify the signed-in user. Pass `token` (a JWT signed by your server with the app identity secret) to mark them verified.
    public static func identify(userId: String, name: String? = nil, email: String? = nil, token: String? = nil, metadata: [String: Any] = [:]) {
        var id: [String: Any] = ["userId": userId]
        if let name { id["name"] = name }
        if let email { id["email"] = email }
        if let token { id["token"] = token }
        if !metadata.isEmpty { id["metadata"] = metadata }
        shared.identify(id)
    }
    /// Inngame's purchase token for this user, as a UUID (nil before the first session).
    /// `product.purchase(options: [.appAccountToken(token)])` lets App Store notifications find the user.
    /// True while the studio's support is unavailable (workspace suspended). See `Inngame.shared.isUnavailable`.
    public static var isUnavailable: Bool { shared.isUnavailable }
    public static var purchaseToken: UUID? { shared.user?.purchaseToken.flatMap(UUID.init(uuidString:)) }
    /// The user signed out of your app: this device starts over as a new anonymous user.
    public static func logout() { Task { await shared.logout() } }
    /// Context attached to the user's next messages (screen, plan, order id…).
    public static func setContext(_ key: String, _ value: Any?) { shared.context[key] = value.map { JSONValue($0) } }
    public static func setPushToken(_ deviceToken: Data, sandbox: Bool = false) {
        shared.pushToken = (deviceToken.map { String(format: "%02x", $0) }.joined(), sandbox ? "apns_sandbox" : "apns")
        Task { await shared.sendPushToken() }
    }
    /// Track an event (automations can answer it, or open the chat).
    public static func track(_ name: String, properties: [String: Any] = [:]) { Task { await shared.track(name, properties: properties) } }
    /// True if the notification came from Inngame; asks the app to open the chat.
    @discardableResult public static func handleNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard userInfo["inngame"] != nil else { return false }
        shared.wantsToOpen = true
        return true
    }
    #if canImport(UIKit)
    /// UIKit: present the chat modally.
    public static func present(from vc: UIViewController) {
        let host = UIHostingController(rootView: InngameChatView())
        host.modalPresentationStyle = .pageSheet
        vc.present(host, animated: true)
    }
    #endif

    /// Apple's page to request a refund or report a problem with a purchase.
    nonisolated static let reportProblemURL = URL(string: "https://reportaproblem.apple.com/")!

    /// Card links: http(s) or an app deep link, never javascript:, data:, file:…
    nonisolated static func isSafeCardURL(_ url: URL) -> Bool {
        !["javascript", "data", "file", "vbscript", "blob", "about"].contains(url.scheme?.lowercased() ?? "")
    }

    nonisolated public static func baseLanguage(_ s: String) -> String { String(s.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "en") }

    // MARK: - Instance

    func configure(appKey: String, baseURL: URL) {
        let saved = KeychainStore.get("token.\(appKey)") ?? KeychainStore.fallback("token.\(appKey)")
        configure(api: APIClient(baseURL: baseURL, appKey: appKey, token: saved))
    }

    /// Tests pass a client on a stubbed URLSession.
    func configure(api client: APIClient, monitorNetwork: Bool = true) {
        let appKey = client.appKey
        api = client
        client.onSuspended = { [weak self] on in Task { @MainActor in self?.setUnavailable(on) } }
        pending = Self.loadPending(appKey)
        startTask = Task { await start() }
        guard monitorNetwork else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, !self.isUnavailable else { return } // support unavailable: the slow recheck asks again
                // No session yet (first launch offline): open it now, which also sends the queue.
                if self.api?.token == nil || !self.isReady { self.startTask = Task { await self.start() } } else { await self.retryPending() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "inngame.network"))
        network = monitor
    }

    private var language: String { Locale.preferredLanguages.first ?? Locale.current.identifier }

    private func device() -> [String: Any] {
        var d: [String: Any] = ["sdkVersion": Inngame.sdkVersion, "language": language, "locale": Locale.current.identifier]
        d["appVersion"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        #if os(iOS)
        d["platform"] = "ios"
        d["os"] = "iOS \(UIDevice.current.systemVersion)"
        var sys = utsname(); uname(&sys)
        d["model"] = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        #elseif os(macOS)
        d["platform"] = "macos"
        d["os"] = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
        return d
    }

    private func start() async {
        guard let api else { return }
        let identity = pendingIdentity
        do {
            var body: [String: Any] = ["device": device()]
            if let identity { body["identity"] = identity; self.pendingIdentity = nil }
            let s: SessionResponse = try await api.request("POST", "/session", body: body)
            setUnavailable(false)
            api.token = s.token
            KeychainStore.set("token.\(api.appKey)", s.token)
            user = s.user; unreadCount = s.unread; config = s.config; isBlocked = s.user.blocked ?? false
            isReady = true
            startRealtime()
            await loadMessages()
            await sendPushToken()
            await retryPending()
        } catch let e as InngameError where e.isSuspension {
            if pendingIdentity == nil { pendingIdentity = identity } // sent with the session that works
            setUnavailable(true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Support unavailable (workspace suspended)

    private func setUnavailable(_ on: Bool) {
        api?.suspended = on
        if on { suspension.lastCheck = Date() }
        guard isUnavailable != on else { return }
        isUnavailable = on
        if on {
            realtime?.stop()
            isTeamTyping = false
            for p in pending where p.failed { setFailed(p.clientId, false) } // waiting, not "not sent"
            recheckLoop?.cancel()
            recheckLoop = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    guard let self, !Task.isCancelled, self.isUnavailable else { return }
                    if self.suspension.recheckDue(now: Date(), chatOpen: self.isChatVisible) { self.recheck() }
                }
            }
        } else {
            recheckLoop?.cancel(); recheckLoop = nil
        }
    }

    /// Asks the server again with a new session; when it works, the chat comes back and the queue is sent.
    func recheck() {
        suspension.lastCheck = Date()
        startTask = Task { await start() }
    }

    func identify(_ identity: [String: Any]) {
        guard let api else { pendingIdentity = identity; return }
        Task {
            await startTask?.value
            guard api.token != nil else { pendingIdentity = identity; startTask = Task { await start() }; return }
            do {
                let r: IdentifyResponse = try await api.request("POST", "/identify", body: identity)
                user = r.user; unreadCount = r.unread
                await loadMessages()
            } catch let e as InngameError where e.isSuspension {
                pendingIdentity = identity // sent with the session that works once support is back
            } catch { lastError = error.localizedDescription }
        }
    }

    func logout() async {
        guard let api else { return }
        _ = try? await api.request("POST", "/logout", body: [:]) as [String: Bool]
        messages = []; unreadCount = 0
        pending = []; savePending() // the next user doesn't send the previous one's messages
        await start()
    }

    private func startRealtime() {
        realtime?.stop()
        guard !isUnavailable else { return }
        let rt = Realtime(url: { [weak api] in api?.webSocketURL() }) { [weak self] ev in
            Task { @MainActor in self?.handle(ev) }
        }
        realtime = rt
        rt.start()
    }

    private func handle(_ ev: Realtime.Event) {
        switch ev {
        case .message(let m): insert(m); if !m.isFromPlayer { isTeamTyping = false; if isChatVisible { Task { await markRead() } } else { unreadCount += 1 } }
        case .retracted(let id, let unread):
            // The team unsent a message: it leaves the chat at once.
            messages.removeAll { $0.id == id }
            if let unread { unreadCount = unread }
        case .read: break
        case .typing:
            isTeamTyping = true
            typingReset?.cancel()
            typingReset = Task { try? await Task.sleep(nanoseconds: 6_000_000_000); if !Task.isCancelled { isTeamTyping = false } }
        case .blocked(let b): isBlocked = b
        case .reconnected: Task { await loadMessages() }
        case .config:
            // The studio changed a setting (announcement, appearance, office hours): reload it, a few seconds apart per device.
            Task {
                try? await Task.sleep(nanoseconds: UInt64.random(in: 0...5_000_000_000))
                let lang = language.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                if let api, let c: InngameRemoteConfig = try? await api.request("GET", "/config?lang=\(lang)") { config = c }
            }
        }
    }

    private func insert(_ m: InngameMessage) {
        if let i = messages.firstIndex(where: { $0.id == m.id || ($0.clientId != nil && $0.clientId == m.clientId) }) { messages[i] = m }
        else { messages.append(m); messages.sort { $0.seq < $1.seq } }
    }

    // MARK: - Messages

    public func loadMessages() async {
        guard let api, api.token != nil else { return }
        do {
            let r: MessagesResponse = try await api.request("GET", "/messages")
            messages = r.messages; hasMore = r.hasMore; unreadCount = r.unread
        } catch let e as InngameError where e.isSuspension {
        } catch { lastError = error.localizedDescription }
    }

    public func loadOlder() async {
        guard let api, let first = messages.first, hasMore else { return }
        if let r: MessagesResponse = try? await api.request("GET", "/messages", query: ["before": String(first.seq)]) {
            messages = r.messages + messages; hasMore = r.hasMore
        }
    }

    public func send(_ text: String, imageData: Data? = nil) async {
        guard let api else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || imageData != nil else { return }
        await startTask?.value
        let clientId = UUID().uuidString
        if imageData == nil {
            // Text only: queued first, so nothing is lost without network.
            let p = InngamePendingMessage(clientId: clientId, body: body, createdAt: Date().timeIntervalSince1970 * 1000, failed: false)
            pending.append(p)
            if pending.count > 20 { pending.removeFirst(pending.count - 20) } // the same 20 as on disk
            savePending()
            await deliver(p)
            return
        }
        do {
            var attachments: [[String: Any]] = []
            if let imageData {
                let up = try await api.upload(data: imageData, filename: "photo.jpg", mimeType: "image/jpeg")
                let a = up.attachment
                attachments.append(["key": a.key, "type": a.type, "size": a.size, "width": a.width as Any, "height": a.height as Any].compactMapValues { $0 is NSNull ? nil : $0 })
            }
            var payload: [String: Any] = ["body": body, "clientId": clientId, "attachments": attachments]
            if !context.isEmpty, let d = try? JSONEncoder().encode(context), let obj = try? JSONSerialization.jsonObject(with: d) { payload["context"] = obj }
            let r: PostMessageResponse = try await api.request("POST", "/messages", body: payload)
            var m = r.message; m.clientId = clientId
            insert(m)
        } catch let e as InngameError {
            // The server's message is already in the user's language ("This image can't be sent.", translated).
            lastError = e.message ?? (e.code == "photo_rejected" ? "This image can't be sent." : e.code)
        } catch { lastError = error.localizedDescription }
    }

    /// Sends the queued messages again (also done at launch and when the network comes back).
    public func retryPending() async {
        guard !isUnavailable else { return }
        // Already accepted (the reply was lost on the way back): it is in the history, not "not sent".
        let known = Set(messages.compactMap(\.clientId))
        if pending.contains(where: { known.contains($0.clientId) }) { pending.removeAll { known.contains($0.clientId) }; savePending() }
        for p in pending { await deliver(p) }
    }

    private func deliver(_ p: InngamePendingMessage) async {
        guard let api, !delivering.contains(p.clientId), pending.contains(where: { $0.clientId == p.clientId }) else { return }
        guard !isUnavailable else { return } // kept until support is back
        // No session yet: show the retry button; the queue leaves when the session opens.
        guard api.token != nil, isReady else { setFailed(p.clientId, true); return }
        delivering.insert(p.clientId)
        defer { delivering.remove(p.clientId) }
        setFailed(p.clientId, false)
        do {
            var payload: [String: Any] = ["body": p.body, "clientId": p.clientId, "attachments": [Any]()]
            if !context.isEmpty, let d = try? JSONEncoder().encode(context), let obj = try? JSONSerialization.jsonObject(with: d) { payload["context"] = obj }
            let r: PostMessageResponse = try await api.request("POST", "/messages", body: payload)
            var m = r.message; m.clientId = p.clientId
            // Logged out meanwhile: the queue was cleared, the message isn't the new user's.
            guard pending.contains(where: { $0.clientId == p.clientId }) else { return }
            pending.removeAll { $0.clientId == p.clientId }; savePending()
            insert(m)
        } catch let e as InngameError where e.isSuspension {
            // Support unavailable: the message is fine, it waits for support to come back.
            setFailed(p.clientId, false)
            setUnavailable(true)
        } catch let e as InngameError where Self.isPermanent(e.status) {
            // Refused by the server (blocked, too long…): sending it again would fail forever.
            pending.removeAll { $0.clientId == p.clientId }; savePending()
            if e.code == "blocked" { isBlocked = true }
            lastError = e.message ?? e.code
        } catch {
            setFailed(p.clientId, true)
        }
    }

    nonisolated static func isPermanent(_ status: Int) -> Bool { status >= 400 && status < 500 && ![401, 408, 429].contains(status) }

    private func setFailed(_ clientId: String, _ failed: Bool) {
        guard let i = pending.firstIndex(where: { $0.clientId == clientId }), pending[i].failed != failed else { return }
        pending[i].failed = failed; savePending()
    }

    private static func pendingKey(_ appKey: String) -> String { "inngame.pending.\(appKey)" }
    private static func loadPending(_ appKey: String) -> [InngamePendingMessage] {
        guard let d = UserDefaults.standard.data(forKey: pendingKey(appKey)), let list = try? JSONDecoder().decode([InngamePendingMessage].self, from: d) else { return [] }
        return list.map { var p = $0; p.failed = true; return p }
    }
    private func savePending() {
        guard let api else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(pending.suffix(20))), forKey: Self.pendingKey(api.appKey))
    }

    public func sendTyping() {
        if let id = messages.last?.conversationId { realtime?.sendTyping(conversationId: id) }
    }

    public func markRead() async {
        guard let api, api.token != nil, unreadCount > 0 || messages.contains(where: { !$0.isFromPlayer && $0.readAt == nil }) else { return }
        _ = try? await api.request("POST", "/read", body: [:]) as UnreadResponse
        unreadCount = 0
    }

    public func cardAction(_ message: InngameMessage, action: String) async {
        guard let api else { return }
        setLastAction(message.id, action)
        _ = try? await api.request("POST", "/cards/\(message.id)/action", body: ["action": action]) as [String: Bool]
    }

    /// Shows the card's new state right away (claimed, failed…).
    private func setLastAction(_ messageId: String, _ action: String, extra: [String: JSONValue] = [:]) {
        guard let i = messages.firstIndex(where: { $0.id == messageId }), case .object(var o)? = messages[i].card else { return }
        o["lastAction"] = .string(action)
        for (k, v) in extra { o[k] = v }
        messages[i].card = .object(o)
    }

    private var claiming = Set<String>()

    /// "item" card: the item is granted only once the server confirms this device won the claim (the team may have
    /// unsent it, or another device claimed it). The nonce is kept, so a retry after a lost response still grants.
    /// Returns true when `onItemGranted` was called.
    @discardableResult public func claimItem(_ message: InngameMessage) async -> Bool {
        guard let api, let item = message.parsedCard?.item(messageId: message.id), message.parsedCard?.lastAction != "claimed",
              let grant = Inngame.onItemGranted, !claiming.contains(message.id) else { return false }
        claiming.insert(message.id); defer { claiming.remove(message.id) }
        let key = "inngame.claim.\(message.id)"
        let nonce = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(nonce, forKey: key)
        do {
            let r: ClaimResponse = try await api.request("POST", "/cards/\(message.id)/action", body: ["action": "claimed", "nonce": nonce])
            setLastAction(message.id, "claimed")
            UserDefaults.standard.removeObject(forKey: key)
            if r.granted == true { grant(item); return true }
        } catch let e as InngameError where e.status == 404 {
            // Unsent by the team: never granted.
            messages.removeAll { $0.id == message.id }
            UserDefaults.standard.removeObject(forKey: key)
        } catch {}
        return false
    }

    /// "restore" card: the app's handler, or StoreKit's `AppStore.sync()`. Returns false if it failed.
    func restorePurchases() async -> Bool {
        if let h = Inngame.onRestorePurchases { h(); return true }
        #if os(iOS) || os(macOS)
        do { try await AppStore.sync(); return true } catch { return false }
        #else
        return false
        #endif
    }

    /// Satisfaction card ("rating"): sends the user's score from 1 to 5. The server keeps the first score only.
    public func rate(_ message: InngameMessage, score: Int) async {
        guard let api, (1...5).contains(score) else { return }
        _ = try? await api.request("POST", "/cards/\(message.id)/action", body: ["action": "rated", "rating": score]) as JSONValue
    }

    public func searchFAQ(_ query: String) async -> [InngameArticle] {
        guard let api else { return [] }
        return (try? await api.request("GET", "/faq", query: query.isEmpty ? [:] : ["q": query]) as FaqResponse)?.articles ?? []
    }

    /// GDPR: erase this user's data on Inngame.
    public func deleteMyData() async throws {
        guard let api else { return }
        _ = try await api.request("POST", "/delete-data", body: [:]) as [String: Bool]
        messages = []; unreadCount = 0
        await start()
    }

    func track(_ name: String, properties: [String: Any]) async {
        guard let api else { return }
        await startTask?.value
        if let r: EventResponse = try? await api.request("POST", "/events", body: ["name": name, "props": properties, "opensChat": true]), r.openChat == true {
            wantsToOpen = true
        }
    }

    private func sendPushToken() async {
        guard let api, api.token != nil, let (token, kind) = pushToken else { return }
        _ = try? await api.request("POST", "/push", body: ["token": token, "kind": kind]) as [String: Bool]
    }
}
