import Foundation

/// A loosely typed JSON value (cards, appearance, context).
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }

    init(_ any: Any?) {
        switch any {
        case let v as String: self = .string(v)
        case let v as Bool: self = .bool(v)
        case let v as Int: self = .number(Double(v))
        case let v as Double: self = .number(v)
        case let v as Float: self = .number(Double(v))
        case let v as [String: Any]: self = .object(v.mapValues { JSONValue($0) })
        case let v as [Any]: self = .array(v.map { JSONValue($0) })
        default: self = .null
        }
    }
}

public struct InngameUser: Codable, Hashable, Sendable {
    public let id: String
    public let name: String?
    public let email: String?
    public let externalId: String?
    public let verified: Bool?
    public let language: String?
    public let blocked: Bool?
    /// UUID issued by Inngame for this user. Pass it as StoreKit's `appAccountToken`
    /// (or as the RevenueCat / Adapty / Superwall app user id) so subscription events find the user.
    public let purchaseToken: String?
}

public struct InngameAttachment: Codable, Hashable, Sendable {
    public let type: String
    public let size: Int?
    public let width: Int?
    public let height: Int?
    public let name: String?
    public let url: URL?
    public var isImage: Bool { type.hasPrefix("image/") }
}

/// Raw attachment returned by an upload, sent back with the message.
struct UploadedAttachment: Codable, Sendable {
    let key: String
    let type: String
    let size: Int
    let width: Int?
    let height: Int?
    let name: String?
}

public struct InngameCard: Hashable, Sendable {
    public let kind: String           // review, link, offer, screen, item, refund
    public let label: String?
    public let url: URL?
    public let raw: JSONValue
    init?(_ v: JSONValue?) {
        guard let v, let kind = v["kind"]?.string else { return nil }
        self.kind = kind
        self.label = v["label"]?.string
        self.url = v["url"]?.string.flatMap(URL.init(string:))
        self.raw = v
    }
}

public struct InngameMessage: Codable, Identifiable, Hashable, Sendable {
    public enum Author: String, Codable, Sendable { case user, team, ai, system, note }
    public struct TeamAuthor: Codable, Hashable, Sendable { public let name: String?; public let avatar: URL? }

    public let id: String
    public let conversationId: String
    public let seq: Int
    public let authorType: Author
    public let body: String
    public let lang: String?
    public let translations: [String: String]?
    public let attachments: [InngameAttachment]
    let card: JSONValue?
    public let status: String
    public let createdAt: Double
    public let readAt: Double?
    public let author: TeamAuthor?
    /// Local only: id used to deduplicate an optimistic message.
    public var clientId: String?

    public var parsedCard: InngameCard? { InngameCard(card) }
    public var isFromPlayer: Bool { authorType == .user }
    public var date: Date { Date(timeIntervalSince1970: createdAt / 1000) }

    /// Text shown to the player: the translation into their language when the team wrote in another one.
    public func text(for language: String?) -> String {
        guard !isFromPlayer, let lang = language.map(Inngame.baseLanguage), let t = translations?[lang], !t.isEmpty else { return body }
        return t
    }
}

public struct InngameArticle: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let body: String
}

public struct InngameRemoteConfig: Codable, Sendable {
    public let appearance: JSONValue?
    public let photosEnabled: Bool
    public let verifiedOnly: Bool
    public let translation: Bool
    public let faq: Bool
    /// Whether the team is around and how fast it usually replies (nil on older servers).
    public let availability: InngameAvailability?
}

public struct InngameAvailability: Codable, Sendable, Equatable {
    public let online: Bool
    /// "minutes", "hours", "day", or nil when there is too little history.
    public let replyTime: String?
    /// Next opening when away, Unix ms.
    public let nextOpenAt: Double?

    /// The line shown under the chat title, in the player's language and local time.
    public func text(now: Date = Date(), locale: Locale = .current) -> String? {
        if !online {
            guard let ms = nextOpenAt else { return nil }
            let at = Date(timeIntervalSince1970: ms / 1000)
            if at <= now { return nil } // the team is back
            let f = DateFormatter()
            f.locale = locale
            f.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(at, inSameDayAs: now) ? "jmm" : "EEEjmm")
            return String(format: L.t("Away · back %@"), f.string(from: at))
        }
        switch replyTime {
        case "minutes": return L.t("Usually replies in a few minutes")
        case "hours": return L.t("Usually replies in a few hours")
        case "day": return L.t("Usually replies within a day")
        default: return nil
        }
    }
}

struct SessionResponse: Codable { let token: String; let user: InngameUser; let conversationId: String?; let unread: Int; let config: InngameRemoteConfig }
struct IdentifyResponse: Codable { let user: InngameUser; let conversationId: String?; let unread: Int }
struct MessagesResponse: Codable { let conversationId: String?; let messages: [InngameMessage]; let hasMore: Bool; let unread: Int }
struct PostMessageResponse: Codable { let conversationId: String; let message: InngameMessage }
struct UploadResponse: Codable { let attachment: UploadedAttachment; let url: URL }
struct UnreadResponse: Codable { let unread: Int }
struct FaqResponse: Codable { let articles: [InngameArticle] }
struct EventResponse: Codable { let ok: Bool; let openChat: Bool? }

/// A message written on this device that the server hasn't accepted yet.
public struct InngamePendingMessage: Codable, Identifiable, Hashable, Sendable {
    public let clientId: String
    public let body: String
    public let createdAt: Double
    /// The last attempt failed (no network…); it will be sent again.
    public var failed: Bool
    public var id: String { clientId }
}

public struct InngameError: Error, LocalizedError, Sendable {
    public let status: Int
    public let code: String
    public let message: String?
    public var errorDescription: String? { message ?? code }
    /// The studio's support is unavailable (its Inngame workspace is suspended).
    public var isSuspension: Bool { status == 403 && code == "org_suspended" }
    static let suspended = InngameError(status: 403, code: "org_suspended", message: "Support is unavailable right now.")
}

/// When to ask the server again while support is unavailable: every 10 minutes while the chat is open,
/// and when the chat opens (at most once a minute). Pure logic, unit-tested.
struct SuspensionClock: Sendable {
    static let recheckInterval: TimeInterval = 600
    static let openGap: TimeInterval = 60
    var lastCheck: Date = .distantPast

    func recheckDue(now: Date, chatOpen: Bool) -> Bool { chatOpen && now.timeIntervalSince(lastCheck) >= Self.recheckInterval }
    func recheckOnOpen(now: Date) -> Bool { now.timeIntervalSince(lastCheck) >= Self.openGap }
}
