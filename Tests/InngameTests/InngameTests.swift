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
    func testOnlyWebLinksAndDeepLinksOpen() {
        XCTAssertTrue(Inngame.isSafeCardURL(URL(string: "https://example.com")!))
        XCTAssertTrue(Inngame.isSafeCardURL(URL(string: "myapp://screen/shop")!))
        XCTAssertFalse(Inngame.isSafeCardURL(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(Inngame.isSafeCardURL(URL(string: "file:///etc/passwd")!))
    }
}
