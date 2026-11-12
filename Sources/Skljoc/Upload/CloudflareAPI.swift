import Foundation

enum CloudflareError: LocalizedError {
    case api(status: Int, messages: [String])
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .api(401, _), .api(403, _):
            "Cloudflare didn't accept the API token, or it lacks a permission. Create it with the button in Settings, which picks the right ones."
        case .api(_, let messages):
            messages.isEmpty ? "Cloudflare returned an error." : messages.joined(separator: " ")
        case .invalidResponse:
            "Cloudflare sent something unexpected."
        }
    }

    /// Cloudflare's error codes, for telling "missing" apart from real failures.
    var codes: [Int] {
        if case .api(_, let messages) = self {
            return messages.compactMap { Int($0.split(separator: ":").first ?? "") }
        }
        return []
    }
}

/// The small part of the Cloudflare REST API that setting up the Worker needs.
struct CloudflareAPI: Sendable {
    let token: String
    private static let base = URL(string: "https://api.cloudflare.com/client/v4/")!

    struct Account: Decodable { var id: String; var name: String }
    struct Zone: Decodable { var id: String; var name: String; var account: Account }
    struct Database: Decodable { var uuid: String; var name: String }
    struct Script: Decodable { var id: String }
    struct Subdomain: Decodable { var subdomain: String }
    struct QueryResult: Decodable { var results: [[String: JSONValue]]? }
    struct Ignored: Decodable { init(from decoder: Decoder) throws {} }

    func accounts() async throws -> [Account] {
        try await request("GET", "accounts?per_page=50")
    }

    func zone(named name: String) async throws -> Zone? {
        let zones: [Zone] = try await request("GET", "zones?name=\(name)")
        return zones.first
    }

    func bucketExists(_ name: String, account: String) async throws -> Bool {
        do {
            let _: Ignored = try await request("GET", "accounts/\(account)/r2/buckets/\(name)")
            return true
        } catch let error as CloudflareError where error.codes.contains(10006) {
            return false
        }
    }

    func createBucket(_ name: String, account: String) async throws {
        let _: Ignored = try await request("POST", "accounts/\(account)/r2/buckets", json: ["name": name])
    }

    func database(named name: String, account: String) async throws -> Database? {
        let databases: [Database] = try await request("GET", "accounts/\(account)/d1/database?name=\(name)")
        return databases.first { $0.name == name }
    }

    func createDatabase(_ name: String, account: String) async throws -> Database {
        try await request("POST", "accounts/\(account)/d1/database", json: ["name": name])
    }

    func query(_ sql: String, database: String, account: String) async throws -> [QueryResult] {
        try await request("POST", "accounts/\(account)/d1/database/\(database)/query", json: ["sql": sql])
    }

    func scriptExists(_ name: String, account: String) async throws -> Bool {
        let scripts: [Script] = try await request("GET", "accounts/\(account)/workers/scripts")
        return scripts.contains { $0.id == name }
    }

    /// Uploads and deploys ES modules. `metadata` follows Cloudflare's multipart upload metadata.
    func uploadScript(_ name: String, account: String, metadata: [String: Any], modules: [(name: String, source: Data)]) async throws {
        let boundary = "skljoc-\(UUID().uuidString)"
        var body = Data()
        func part(name: String, filename: String? = nil, type: String, data: Data) {
            body.append(Data("--\(boundary)\r\n".utf8))
            let file = filename.map { "; filename=\"\($0)\"" } ?? ""
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\(file)\r\n".utf8))
            body.append(Data("Content-Type: \(type)\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        part(name: "metadata", type: "application/json", data: try JSONSerialization.data(withJSONObject: metadata))
        for module in modules {
            part(name: module.name, filename: module.name, type: "application/javascript+module", data: module.source)
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        let _: Ignored = try await request("PUT", "accounts/\(account)/workers/scripts/\(name)", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }

    func setSchedules(_ crons: [String], script: String, account: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: crons.map { ["cron": $0] })
        let _: Ignored = try await request("PUT", "accounts/\(account)/workers/scripts/\(script)/schedules", body: body, contentType: "application/json")
    }

    /// The same call Wrangler makes: it also creates the DNS record and certificate.
    /// An existing DNS record on the hostname is left alone, so this fails instead of replacing it.
    func attachDomain(_ hostname: String, zone: String, script: String, account: String) async throws {
        let _: Ignored = try await request("PUT", "accounts/\(account)/workers/scripts/\(script)/domains/records", json: [
            "override_scope": true,
            "override_existing_origin": true,
            "override_existing_dns_record": false,
            "origins": [["hostname": hostname, "zone_id": zone]],
        ])
    }

    func workersSubdomain(account: String) async throws -> String? {
        let subdomain: Subdomain? = try? await request("GET", "accounts/\(account)/workers/subdomain")
        return subdomain?.subdomain
    }

    func enableWorkersDev(script: String, account: String) async throws {
        let _: Ignored = try await request("POST", "accounts/\(account)/workers/scripts/\(script)/subdomain", json: ["enabled": true])
    }

    // MARK: Plumbing

    private struct Envelope<Result: Decodable>: Decodable {
        struct Message: Decodable { var code: Int; var message: String }
        var success: Bool
        var errors: [Message]?
        var result: Result?
    }

    private func request<Result: Decodable>(_ method: String, _ path: String, json: [String: Any]) async throws -> Result {
        try await request(method, path, body: try JSONSerialization.data(withJSONObject: json), contentType: "application/json")
    }

    private func request<Result: Decodable>(_ method: String, _ path: String, body: Data? = nil, contentType: String? = nil) async throws -> Result {
        guard let url = URL(string: path, relativeTo: Self.base) else { throw CloudflareError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let envelope = try? JSONDecoder().decode(Envelope<Result>.self, from: data) else {
            if (200..<300).contains(status), let empty = try? JSONDecoder().decode(Result.self, from: Data("{}".utf8)) { return empty }
            throw CloudflareError.api(status: status, messages: [String(data: data.prefix(300), encoding: .utf8) ?? ""])
        }
        guard envelope.success, (200..<300).contains(status) else {
            throw CloudflareError.api(status: status, messages: (envelope.errors ?? []).map { "\($0.code): \($0.message)" })
        }
        if let result = envelope.result { return result }
        if let empty = try? JSONDecoder().decode(Result.self, from: Data("{}".utf8)) { return empty }
        throw CloudflareError.invalidResponse
    }
}

/// Any JSON value, for D1 query rows.
enum JSONValue: Decodable, Sendable {
    case string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .string((try? container.decode(String.self)) ?? "") }
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
