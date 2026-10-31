import Foundation
import Network
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
    public static let sdkVersion = "0.2.0"
    public static let shared = Inngame()

    @Published public private(set) var messages: [InngameMessage] = []
    @Published public private(set) var unreadCount = 0
    @Published public private(set) var user: InngameUser?
    @Published public private(set) var config: InngameRemoteConfig?
    @Published public private(set) var isTeamTyping = false
    @Published public private(set) var isBlocked = false
    @Published public private(set) var hasMore = false
    @Published public private(set) var isReady = false
    @Published public internal(set) var isChatVisible = false { didSet { if isChatVisible { Task { await markRead() } } } }
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

    // MARK: - Static API

    public static func configure(appKey: String, baseURL: URL = URL(string: "https://inngame.meffysto.workers.dev")!) { shared.configure(appKey: appKey, baseURL: baseURL) }
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

    /// Card links: http(s) or an app deep link, never javascript:, data:, file:…
    nonisolated static func isSafeCardURL(_ url: URL) -> Bool {
        !["javascript", "data", "file", "vbscript", "blob", "about"].contains(url.scheme?.lowercased() ?? "")
    }

    nonisolated public static func baseLanguage(_ s: String) -> String { String(s.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "en") }

    // MARK: - Instance

    func configure(appKey: String, baseURL: URL) {
        let saved = KeychainStore.get("token.\(appKey)") ?? KeychainStore.fallback("token.\(appKey)")
        api = APIClient(baseURL: baseURL, appKey: appKey, token: saved)
        pending = Self.loadPending(appKey)
        startTask = Task { await start() }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self else { return }
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
        do {
            var body: [String: Any] = ["device": device()]
            if let pendingIdentity { body["identity"] = pendingIdentity; self.pendingIdentity = nil }
            let s: SessionResponse = try await api.request("POST", "/session", body: body)
            api.token = s.token
            KeychainStore.set("token.\(api.appKey)", s.token)
            user = s.user; unreadCount = s.unread; config = s.config; isBlocked = s.user.blocked ?? false
            isReady = true
            startRealtime()
            await loadMessages()
            await sendPushToken()
            await retryPending()
        } catch {
            lastError = error.localizedDescription
        }
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
            lastError = e.code == "photo_rejected" ? "This image can't be sent." : (e.message ?? e.code)
        } catch { lastError = error.localizedDescription }
    }

    /// Sends the queued messages again (also done at launch and when the network comes back).
    public func retryPending() async {
        // Already accepted (the reply was lost on the way back): it is in the history, not "not sent".
        let known = Set(messages.compactMap(\.clientId))
        if pending.contains(where: { known.contains($0.clientId) }) { pending.removeAll { known.contains($0.clientId) }; savePending() }
        for p in pending { await deliver(p) }
    }

    private func deliver(_ p: InngamePendingMessage) async {
        guard let api, !delivering.contains(p.clientId), pending.contains(where: { $0.clientId == p.clientId }) else { return }
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
        _ = try? await api.request("POST", "/cards/\(message.id)/action", body: ["action": action]) as [String: Bool]
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
