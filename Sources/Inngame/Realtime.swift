import Foundation

/// WebSocket to the org hub: new messages, read receipts, typing. Reconnects with backoff.
final class Realtime: NSObject, @unchecked Sendable {
    enum Event { case message(InngameMessage), retracted(String, Int?), read, typing, blocked(Bool), reconnected, config }

    private let makeURL: () -> URL?
    private let onEvent: @Sendable (Event) -> Void
    private var task: URLSessionWebSocketTask?
    private var stopped = true
    private var attempt = 0
    private var pingTimer: Timer?
    private lazy var session = URLSession(configuration: .default)

    init(url: @escaping () -> URL?, onEvent: @escaping @Sendable (Event) -> Void) {
        self.makeURL = url
        self.onEvent = onEvent
    }

    func start() {
        guard stopped else { return }
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    func sendTyping(conversationId: String) {
        send(["type": "typing", "conversationId": conversationId])
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    private func connect() {
        guard !stopped, let url = makeURL() else { return }
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        if attempt > 0 { onEvent(.reconnected) }
        receive(t)
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in self?.send(["type": "ping"]) }
        }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .success(let msg):
                self.attempt = 0
                if case .string(let s) = msg { self.handle(s) }
                self.receive(t)
            case .failure:
                self.scheduleReconnect()
            }
        }
    }

    private func handle(_ s: String) {
        guard let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = obj["type"] as? String else { return }
        switch type {
        case "message":
            if let m = obj["message"], let d = try? JSONSerialization.data(withJSONObject: m), let msg = try? JSONDecoder().decode(InngameMessage.self, from: d) { onEvent(.message(msg)) }
        case "message.retracted": if let id = obj["messageId"] as? String { onEvent(.retracted(id, obj["unread"] as? Int)) }
        case "read": onEvent(.read)
        case "typing": if obj["from"] as? String == "team" { onEvent(.typing) }
        case "blocked": onEvent(.blocked(obj["blocked"] as? Bool ?? true))
        case "config": onEvent(.config)
        default: break
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        task = nil
        attempt += 1
        let delay = min(30, pow(2, Double(min(attempt, 5)))) * Double.random(in: 0.8...1.2)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }
}
