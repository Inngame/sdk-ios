import XCTest
@testable import Inngame

final class ModelTests: XCTestCase {
    let json = """
    {"id":"msg_1","conversationId":"cnv_1","seq":3,"authorType":"team","body":"Try again after the update","lang":"en",
     "translations":{"fr":"Réessaie après la mise à jour"},"attachments":[{"type":"image/jpeg","size":10,"url":"https://x.test/f"}],
     "card":{"kind":"review","label":"Rate us"},"status":"sent","createdAt":1761900000000,"readAt":null,"author":{"name":"Gab","avatar":null}}
    """

    func testDecodeTeamMessage() throws {
        let m = try JSONDecoder().decode(InngameMessage.self, from: Data(json.utf8))
        XCTAssertEqual(m.authorType, .team)
        XCTAssertEqual(m.text(for: "fr-FR"), "Réessaie après la mise à jour")
        XCTAssertEqual(m.text(for: "de"), "Try again after the update")
        XCTAssertEqual(m.parsedCard?.kind, "review")
        XCTAssertEqual(m.parsedCard?.label, "Rate us")
        XCTAssertTrue(m.attachments[0].isImage)
        XCTAssertEqual(m.author?.name, "Gab")
    }

    func testServerDefaultCardLabelsAreTranslated() {
        func card(_ json: String) -> InngameCard { InngameCard(try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))! }
        let fr: (String) -> String = { L.t($0, lang: "fr-FR") }
        // Refund sheet from the server (flag sent since 0.2.2 of the server) and the same card stored before the flag.
        let refund = card(#"{"kind":"refund","label":"Request a refund","defaultLabel":true,"transactionId":"2000000123456789"}"#)
        XCTAssertTrue(refund.usesDefaultLabel)
        XCTAssertEqual(refund.displayLabel(fr), L.t("Request a refund", lang: "fr"))
        XCTAssertNotEqual(refund.displayLabel(fr), "Request a refund")
        XCTAssertEqual(card(#"{"kind":"refund","label":"Request a refund"}"#).displayLabel(fr), refund.displayLabel(fr))
        let review = card(#"{"kind":"review","label":"Rate the game"}"#)
        XCTAssertEqual(review.displayLabel(fr), L.t("Rate the app", lang: "fr"))
        // A label written by the team stays as it is; no label → the SDK's text.
        XCTAssertEqual(card(#"{"kind":"review","label":"Rate us"}"#).displayLabel(fr), "Rate us")
        XCTAssertEqual(card(#"{"kind":"review"}"#).displayLabel(fr), L.t("Rate the app", lang: "fr"))
        XCTAssertEqual(card(#"{"kind":"link","label":"Rate the game"}"#).displayLabel(fr), "Rate the game")
    }

    func testPlayerMessageNeverTranslatedBack() throws {
        let m = try JSONDecoder().decode(InngameMessage.self, from: Data(json.replacingOccurrences(of: "\"team\"", with: "\"user\"").utf8))
        XCTAssertEqual(m.text(for: "fr"), "Try again after the update")
    }

    func testBaseLanguageAndJSONValue() {
        XCTAssertEqual(Inngame.baseLanguage("pt_BR"), "pt")
        XCTAssertEqual(Inngame.baseLanguage("zh-Hant-TW"), "zh")
        let v = JSONValue(["level": 4, "boss": "Hydra", "hard": true] as [String: Any])
        XCTAssertEqual(v["level"]?.number, 4)
        XCTAssertEqual(v["boss"]?.string, "Hydra")
    }

    func testAvailabilityLine() throws {
        let c = try JSONDecoder().decode(InngameRemoteConfig.self, from: Data(#"{"photosEnabled":true,"verifiedOnly":false,"translation":true,"faq":false,"availability":{"online":true,"replyTime":"hours","nextOpenAt":null}}"#.utf8))
        XCTAssertEqual(c.availability?.text(), L.t("Usually replies in a few hours")) // langue de l'appareil
        let old = try JSONDecoder().decode(InngameRemoteConfig.self, from: Data(#"{"photosEnabled":true,"verifiedOnly":false,"translation":true,"faq":false}"#.utf8))
        XCTAssertNil(old.availability)
        let now = Date()
        let away = InngameAvailability(online: false, replyTime: nil, nextOpenAt: (now.timeIntervalSince1970 + 3 * 86400) * 1000)
        XCTAssertTrue(away.text(now: now, locale: Locale(identifier: "en_US"))!.hasPrefix(String(format: L.t("Away · back %@"), "")))
        XCTAssertNil(InngameAvailability(online: true, replyTime: nil, nextOpenAt: nil).text())
    }
}

/// Runs against a real server: INNGAME_TEST_URL=http://localhost:8787 INNGAME_TEST_APP_KEY=app_… swift test
final class LiveTests: XCTestCase {
    func testSessionSendAndRead() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["INNGAME_TEST_URL"].flatMap(URL.init(string:)), let key = env["INNGAME_TEST_APP_KEY"] else { throw XCTSkip("no live server") }
        let api = APIClient(baseURL: url, appKey: key, token: nil)
        let s: SessionResponse = try await api.request("POST", "/session", body: ["device": ["platform": "ios", "language": "fr", "sdkVersion": Inngame.sdkVersion], "identity": ["userId": "ios-live-\(UUID().uuidString.prefix(6))", "name": "Swift"]])
        api.token = s.token
        XCTAssertTrue(s.token.hasPrefix("dev_"))
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let up = try await api.upload(data: png, filename: "p.png", mimeType: "image/png")
        let r: PostMessageResponse = try await api.request("POST", "/messages", body: ["body": "Bonjour depuis iOS", "clientId": "c1", "attachments": [["key": up.attachment.key, "type": up.attachment.type, "size": up.attachment.size]], "context": ["screen": "Settings"]])
        XCTAssertEqual(r.message.body, "Bonjour depuis iOS")
        XCTAssertEqual(r.message.attachments.count, 1)
        let list: MessagesResponse = try await api.request("GET", "/messages")
        XCTAssertEqual(list.messages.last?.id, r.message.id)
        XCTAssertNotNil(api.webSocketURL())
    }
}

final class PendingQueueTests: XCTestCase {
    func testPermanentRefusalsAreDropped() {
        XCTAssertTrue(Inngame.isPermanent(400))
        XCTAssertTrue(Inngame.isPermanent(403))
        XCTAssertTrue(Inngame.isPermanent(413))
        XCTAssertFalse(Inngame.isPermanent(401)) // session expired: retried after a new session
        XCTAssertFalse(Inngame.isPermanent(408))
        XCTAssertFalse(Inngame.isPermanent(429))
        XCTAssertFalse(Inngame.isPermanent(503))
        XCTAssertFalse(Inngame.isPermanent(0))
    }

    func testPendingRoundTrip() throws {
        let p = InngamePendingMessage(clientId: "c1", body: "Lost my save", createdAt: 1, failed: false)
        let back = try JSONDecoder().decode([InngamePendingMessage].self, from: JSONEncoder().encode([p]))
        XCTAssertEqual(back.first?.body, "Lost my save")
        XCTAssertEqual(back.first?.id, "c1")
    }
}

@MainActor
final class PendingLiveTests: XCTestCase {
    /// Without network the message waits on the device; at the next launch it is delivered once.
    func testOfflineMessageIsDeliveredAtNextLaunch() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["INNGAME_TEST_URL"].flatMap(URL.init(string:)), let key = env["INNGAME_TEST_APP_KEY"] else { throw XCTSkip("no live server") }
        UserDefaults.standard.removeObject(forKey: "inngame.pending.\(key)")
        // 1. Server unreachable: the message stays queued, marked failed.
        let offline = Inngame()
        offline.configure(appKey: key, baseURL: URL(string: "http://127.0.0.1:9")!)
        let text = "Lost my save offline \(UUID().uuidString.prefix(6))"
        await offline.send(text)
        XCTAssertEqual(offline.pending.count, 1)
        // 2. Next launch with the network back: sent, removed from the queue, shown once.
        let online = Inngame()
        online.configure(appKey: key, baseURL: url)
        for _ in 0..<50 where !online.pending.isEmpty || online.messages.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(online.pending.isEmpty)
        XCTAssertEqual(online.messages.filter { $0.body == text }.count, 1)
        UserDefaults.standard.removeObject(forKey: "inngame.pending.\(key)")
    }
}

final class CardURLTests: XCTestCase {
    private func card(_ json: String) -> InngameCard { InngameCard(try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))! }

    /// Review cards open the App Store "Write a Review" page (never the system prompt), from the card's id or the dashboard's.
    func testReviewCardOpensWriteReviewPage() throws {
        let ids = try JSONDecoder().decode(InngameStoreIds.self, from: Data(#"{"appStoreId":"6820303869","playPackage":null,"steamAppId":null}"#.utf8))
        XCTAssertEqual(card(#"{"kind":"review","defaultLabel":true,"source":"resolved"}"#).reviewURL(storeIds: ids)?.absoluteString,
                       "https://apps.apple.com/app/id6820303869?action=write-review")
        XCTAssertEqual(card(#"{"kind":"review","appStoreId":"123"}"#).reviewURL(storeIds: ids)?.absoluteString, "https://apps.apple.com/app/id123?action=write-review")
        XCTAssertEqual(card(#"{"kind":"review","url":"https://example.com/r"}"#).reviewURL(storeIds: nil)?.absoluteString, "https://example.com/r")
        XCTAssertNil(card(#"{"kind":"review","url":"javascript:alert(1)"}"#).reviewURL(storeIds: nil))
        XCTAssertNil(card(#"{"kind":"review","appStoreId":"12; rm"}"#).reviewURL(storeIds: nil))
        let cfg = try JSONDecoder().decode(InngameRemoteConfig.self, from: Data(#"{"photosEnabled":true,"verifiedOnly":false,"translation":true,"faq":false,"reviews":{"appStoreId":"42","playPackage":"a.b","steamAppId":null}}"#.utf8))
        XCTAssertEqual(cfg.reviews?.appStoreId, "42")
    }

    func testItemOfferScreenRefundFields() {
        let item = card(#"{"kind":"item","label":"Sorry!","item":{"id":"gems","name":"Gems","quantity":50}}"#)
        XCTAssertEqual(item.item(messageId: "msg_9"), InngameItem(messageId: "msg_9", id: "gems", name: "Gems", quantity: 50))
        XCTAssertEqual(item.customLabel, "Sorry!")
        XCTAssertNil(card(#"{"kind":"link","item":{"id":"x"}}"#).item(messageId: "m"))
        XCTAssertEqual(card(#"{"kind":"item"}"#).displayLabel { $0 }, "Claim")
        XCTAssertEqual(card(#"{"kind":"offer","offerId":"spring"}"#).offerId, "spring")
        XCTAssertEqual(card(#"{"kind":"offer","value":"v"}"#).offerId, "v")
        let screen = card(#"{"kind":"screen","screen":"shop","value":"gems"}"#)
        XCTAssertEqual(screen.screen, "shop"); XCTAssertEqual(screen.value, "gems")
        XCTAssertEqual(card(#"{"kind":"refund","transactionId":"2000000123456789"}"#).transactionId, "2000000123456789")
        XCTAssertEqual(card(#"{"kind":"item","lastAction":"claimed"}"#).lastAction, "claimed")
        XCTAssertEqual(Inngame.reportProblemURL.host, "reportaproblem.apple.com")
        for (lang, t) in L.table { XCTAssertNotNil(t["Claim"], lang); XCTAssertNotNil(t["Claimed"], lang) }
    }

    func testOnlyWebLinksAndDeepLinksOpen() {
        XCTAssertTrue(Inngame.isSafeCardURL(URL(string: "https://example.com")!))
        XCTAssertTrue(Inngame.isSafeCardURL(URL(string: "myapp://screen/shop")!))
        XCTAssertFalse(Inngame.isSafeCardURL(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(Inngame.isSafeCardURL(URL(string: "file:///etc/passwd")!))
    }

    func testChatThemeLogoAndColors() throws {
        let c = try JSONDecoder().decode(InngameRemoteConfig.self, from: Data(##"{"photosEnabled":true,"verifiedOnly":false,"translation":true,"faq":false,"availability":null,"appearance":{"logoUrl":"https://inngame.gg/logos/app_1/abc.png","light":{"accent":"#ff5c8a","incoming":"#e3f4ff","outgoing":"#7a4a21","header":"bad"}}}"##.utf8))
        let t = ChatTheme(appearance: c.appearance, dark: false)
        XCTAssertEqual(t.logoURL?.absoluteString, "https://inngame.gg/logos/app_1/abc.png")
        XCTAssertNil(t.header)
        XCTAssertEqual(t.outgoingText, .white)
        XCTAssertNotEqual(t.incomingText, .white)
        let d = ChatTheme(appearance: JSONValue(["logoUrl": "javascript:alert(1)"] as [String: Any]), dark: true)
        XCTAssertNil(d.logoURL)
        XCTAssertEqual(d.outgoingText, .white)
    }
}

/// Fake server for the suspension tests: 403 org_suspended on everything while `suspended` is true.
final class SuspendedServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var suspended = true
    nonisolated(unsafe) static var log: [String] = []
    nonisolated(unsafe) static var sessionBodies: [[String: Any]] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url!.path.replacingOccurrences(of: "/v1/sdk", with: "")
        let method = request.httpMethod ?? "GET"
        var body: [String: Any] = [:]
        if let s = request.httpBodyStream {
            s.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            s.close()
            body = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        }
        Self.lock.lock(); Self.log.append("\(method) \(path)"); if path == "/session" { Self.sessionBodies.append(body) }; let suspended = Self.suspended; Self.lock.unlock()
        let (status, json): (Int, String)
        if suspended {
            (status, json) = (403, #"{"error":"org_suspended","message":"Support chat is unavailable."}"#)
        } else if path == "/session" {
            (status, json) = (200, #"{"token":"dev_t","user":{"id":"eu_1","blocked":false},"conversationId":"cnv_1","unread":0,"config":{"photosEnabled":true,"verifiedOnly":false,"translation":true,"faq":false}}"#)
        } else if path == "/messages" && method == "POST" {
            let cid = body["clientId"] as? String ?? ""
            (status, json) = (200, #"{"conversationId":"cnv_1","message":{"id":"msg_1","conversationId":"cnv_1","seq":1,"authorType":"user","body":"help","attachments":[],"status":"sent","createdAt":1,"clientId":"\#(cid)"}}"#)
        } else if path == "/messages" {
            (status, json) = (200, #"{"conversationId":"cnv_1","messages":[],"hasMore":false,"unread":0}"#)
        } else {
            (status, json) = (200, #"{"ok":true}"#)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["content-type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func reset(suspended s: Bool) { lock.lock(); suspended = s; log = []; sessionBodies = []; lock.unlock() }
    static var calls: [String] { lock.lock(); defer { lock.unlock() }; return log }
}

@MainActor
final class SuspensionTests: XCTestCase {
    func testRecheckClock() {
        var c = SuspensionClock()
        let t0 = Date()
        XCTAssertTrue(c.recheckOnOpen(now: t0), "never checked")
        c.lastCheck = t0
        XCTAssertFalse(c.recheckOnOpen(now: t0.addingTimeInterval(30)), "opening right after a check doesn't ask again")
        XCTAssertTrue(c.recheckOnOpen(now: t0.addingTimeInterval(61)))
        XCTAssertFalse(c.recheckDue(now: t0.addingTimeInterval(300), chatOpen: true), "not every few seconds")
        XCTAssertFalse(c.recheckDue(now: t0.addingTimeInterval(601), chatOpen: false), "only while the chat is open")
        XCTAssertTrue(c.recheckDue(now: t0.addingTimeInterval(601), chatOpen: true))
        XCTAssertTrue(InngameError(status: 403, code: "org_suspended", message: nil).isSuspension)
        XCTAssertFalse(InngameError(status: 403, code: "forbidden", message: nil).isSuspension)
        XCTAssertFalse(InngameError(status: 401, code: "org_suspended", message: nil).isSuspension)
        XCTAssertNotEqual(L.table["fr"]?["Support is unavailable right now. Please try again later."], nil)
        for (lang, t) in L.table { XCTAssertNotNil(t["Support is unavailable right now. Please try again later."], lang) }
    }

    func testSuspendedWorkspaceKeepsMessagesAndComesBack() async throws {
        let key = "app_suspended_test"
        UserDefaults.standard.removeObject(forKey: "inngame.pending.\(key)")
        defer {
            UserDefaults.standard.removeObject(forKey: "inngame.pending.\(key)")
            KeychainStore.set("token.\(key)", nil)
            UserDefaults.standard.removeObject(forKey: "gg.inngame.token.\(key)")
        }
        SuspendedServer.reset(suspended: true)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SuspendedServer.self]
        let api = APIClient(baseURL: URL(string: "https://api.test")!, appKey: key, token: "dev_t", session: URLSession(configuration: cfg))
        let sdk = Inngame()
        sdk.configure(api: api, monitorNetwork: false)
        for _ in 0..<50 where !sdk.isUnavailable { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(sdk.isUnavailable)
        XCTAssertEqual(SuspendedServer.calls, ["POST /session"])
        XCTAssertNil(sdk.lastError, "no raw error for the player")

        // Nothing reaches the server while support is unavailable; the message waits (not "not sent").
        await sdk.send("help")
        await sdk.track("level_failed", properties: [:])
        sdk.identify(["userId": "p1"])
        sdk.isChatVisible = true // just checked: no new call
        await sdk.retryPending()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(SuspendedServer.calls, ["POST /session"])
        XCTAssertEqual(sdk.pending.count, 1)
        XCTAssertEqual(sdk.pending.first?.failed, false)
        do { try await sdk.deleteMyData(); XCTFail("should throw") } catch let e as InngameError { XCTAssertTrue(e.isSuspension) }

        // Workspace reactivated: the next recheck brings the chat back and sends the waiting message.
        SuspendedServer.reset(suspended: false)
        sdk.recheck()
        for _ in 0..<100 where sdk.isUnavailable || !sdk.pending.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(sdk.isUnavailable)
        XCTAssertTrue(sdk.pending.isEmpty)
        XCTAssertTrue(SuspendedServer.calls.contains("POST /messages"), "\(SuspendedServer.calls)")
        XCTAssertEqual(sdk.messages.first?.body, "help")
        XCTAssertEqual((SuspendedServer.sessionBodies.first?["identity"] as? [String: Any])?["userId"] as? String, "p1", "identity kept for the session that works")
        sdk.isChatVisible = false
    }
}

/// Fake server for item claims and refused photos.
final class CardServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var claims: [String] = []
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url!.path.replacingOccurrences(of: "/v1/sdk", with: "")
        var body: [String: Any] = [:]
        if let s = request.httpBodyStream {
            s.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            s.close()
            body = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        }
        let (status, json): (Int, String)
        switch path {
        case "/session": (status, json) = (200, #"{"token":"dev_t","user":{"id":"eu_1","blocked":false},"conversationId":"cnv_1","unread":0,"config":{"photosEnabled":true,"verifiedOnly":false,"translation":true,"faq":false}}"#)
        case "/messages": (status, json) = (200, #"{"conversationId":"cnv_1","messages":[{"id":"msg_item","conversationId":"cnv_1","seq":1,"authorType":"team","body":"Sorry!","attachments":[],"card":{"kind":"item","item":{"id":"gems","name":"Gems","quantity":50}},"status":"sent","createdAt":1}],"hasMore":false,"unread":0}"#)
        case "/cards/msg_item/action":
            Self.lock.lock(); Self.claims.append(body["nonce"] as? String ?? ""); let first = Self.claims.count == 1; Self.lock.unlock()
            (status, json) = (200, first ? #"{"ok":true,"granted":true}"# : #"{"ok":true,"granted":false}"#)
        case "/uploads": (status, json) = (422, #"{"error":"photo_rejected","message":"Cette image ne peut pas être envoyée."}"#)
        default: (status, json) = (200, #"{"ok":true}"#)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["content-type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class CardActionTests: XCTestCase {
    func testItemClaimedOnceAndPhotoErrorFromServer() async throws {
        let key = "app_card_test"
        defer { KeychainStore.set("token.\(key)", nil); UserDefaults.standard.removeObject(forKey: "gg.inngame.token.\(key)"); Inngame.onItemGranted = nil }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CardServer.self]
        let sdk = Inngame()
        sdk.configure(api: APIClient(baseURL: URL(string: "https://api.test")!, appKey: key, token: "dev_t", session: URLSession(configuration: cfg)), monitorNetwork: false)
        for _ in 0..<50 where sdk.messages.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        let m = try XCTUnwrap(sdk.messages.first)
        // No handler: nothing is claimed (the card stays disabled).
        let none = await sdk.claimItem(m); XCTAssertFalse(none)
        XCTAssertTrue(CardServer.claims.isEmpty)
        var granted: [InngameItem] = []
        Inngame.onItemGranted = { granted.append($0) }
        let ok = await sdk.claimItem(m); XCTAssertTrue(ok)
        XCTAssertEqual(granted, [InngameItem(messageId: "msg_item", id: "gems", name: "Gems", quantity: 50)])
        XCTAssertEqual(sdk.messages.first?.parsedCard?.lastAction, "claimed")
        let again = await sdk.claimItem(sdk.messages.first!); XCTAssertFalse(again, "never twice")
        XCTAssertEqual(granted.count, 1)
        XCTAssertGreaterThanOrEqual(CardServer.claims.first?.count ?? 0, 8, "nonce sent")

        await sdk.send("", imageData: Data([0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(sdk.lastError, "Cette image ne peut pas être envoyée.", "the server's translated text, not a hard-coded English one")
    }
}
