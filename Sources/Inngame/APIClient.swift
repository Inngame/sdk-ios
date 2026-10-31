import Foundation

/// Thin client over the SDK API (`/v1/sdk`). One per app key.
final class APIClient: @unchecked Sendable {
    let baseURL: URL
    let appKey: String
    var token: String?
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(baseURL: URL, appKey: String, token: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.appKey = appKey
        self.token = token
        self.session = session
    }

    func request<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil, query: [String: String] = [:], as: T.Type = T.self) async throws -> T {
        var comps = URLComponents(url: baseURL.appendingPathComponent("v1/sdk" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue(appKey, forHTTPHeaderField: "x-app-key")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await send(req)
    }

    func upload(data: Data, filename: String, mimeType: String, kind: String = "img") async throws -> UploadResponse {
        let boundary = "inngame-\(UUID().uuidString)"
        var comps = URLComponents(url: baseURL.appendingPathComponent("v1/sdk/uploads"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "kind", value: kind)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(appKey, forHTTPHeaderField: "x-app-key")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        return try await send(req)
    }

    func webSocketURL() -> URL? {
        guard let token else { return nil }
        var comps = URLComponents(url: baseURL.appendingPathComponent("v1/sdk/ws"), resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        comps.queryItems = [URLQueryItem(name: "app_key", value: appKey), URLQueryItem(name: "token", value: token)]
        return comps.url
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw InngameError(status: status, code: j?["error"] as? String ?? "http_\(status)", message: j?["message"] as? String)
        }
        return try decoder.decode(T.self, from: data)
    }
}
