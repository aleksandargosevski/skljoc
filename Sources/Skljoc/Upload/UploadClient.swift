import Foundation
import SkljocCore

enum UploadError: LocalizedError {
    case notConfigured
    case server(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Upload isn't set up yet. Add your Worker address and token in Settings → Upload."
        case .server(401, _):
            "The Worker didn't accept the token. Check it in Settings → Upload."
        case .server(let status, let message):
            "The Worker answered \(status): \(message)"
        case .invalidResponse:
            "The Worker sent something unexpected. Is the address right?"
        }
    }
}

/// Talks to the Škljoc Worker: uploads (whole or in parts), options, listing and deleting.
struct UploadClient: Sendable {
    let baseURL: URL
    let token: String

    struct Health: Decodable {
        var ok: Bool
        var version: Int
        var siteName: String?
    }

    struct Page: Decodable {
        var uploads: [UploadedFile]
        var nextOffset: Int?
    }

    func health() async throws -> Health {
        try await send(request("api/health"))
    }

    /// Uploads a file, in parts when it is too big for one request. `progress` gets 0…1.
    func upload(
        _ file: URL, filename: String, contentType: String, options: [String: Any],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UploadedFile {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        var headers = [
            "Content-Type": contentType,
            "X-Skljoc-Filename": filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? "upload",
            "X-Skljoc-Options": try UploadOptions.headerValue(options),
        ]
        if size <= UploadParts.singleRequestLimit {
            var request = request("api/uploads", method: "POST", headers: headers)
            request.setValue(String(size), forHTTPHeaderField: "Content-Length")
            let tracker = ProgressTracker(total: Int64(size), report: progress)
            let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file, delegate: tracker)
            return try decode(data, response)
        }

        struct Started: Decodable { var id: String; var uploadId: String }
        struct Done: Decodable { var partNumber: Int; var etag: String }
        let started: Started = try await send(request("api/uploads/multipart", method: "POST", headers: headers))
        headers.removeAll()
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var finished: [[String: Any]] = []
            var sent: Int64 = 0
            for part in UploadParts.plan(fileSize: size) {
                try handle.seek(toOffset: UInt64(part.offset))
                let data = handle.readData(ofLength: part.length)
                let already = sent
                let tracker = ProgressTracker(total: Int64(size)) { fraction in
                    progress((Double(already) + fraction * Double(data.count)) / Double(size))
                }
                tracker.total = Int64(data.count)
                let partRequest = request("api/uploads/multipart/\(started.id)/\(part.number)", method: "PUT")
                let (body, response) = try await URLSession.shared.upload(for: partRequest, from: data, delegate: tracker)
                let done: Done = try decode(body, response)
                finished.append(["partNumber": done.partNumber, "etag": done.etag])
                sent += Int64(data.count)
            }
            let completion = try JSONSerialization.data(withJSONObject: ["parts": finished])
            var complete = request("api/uploads/multipart/\(started.id)/complete", method: "POST", headers: ["Content-Type": "application/json"])
            complete.httpBody = completion
            return try await send(complete)
        } catch {
            _ = try? await send(request("api/uploads/multipart/\(started.id)", method: "DELETE")) as [String: String]
            throw error
        }
    }

    func setPoster(_ jpeg: Data, for id: String) async throws {
        var request = request("api/uploads/\(id)/poster", method: "PUT", headers: ["Content-Type": "image/jpeg"])
        request.httpBody = jpeg
        let _: [String: Bool] = try await send(request)
    }

    func list(offset: Int = 0) async throws -> Page {
        try await send(request("api/uploads?limit=100&offset=\(offset)"))
    }

    func update(_ id: String, options: [String: Any]) async throws -> UploadedFile {
        var request = request("api/uploads/\(id)", method: "PATCH", headers: ["Content-Type": "application/json"])
        request.httpBody = try JSONSerialization.data(withJSONObject: options)
        return try await send(request)
    }

    func delete(_ id: String) async throws {
        let _: [String: String] = try await send(request("api/uploads/\(id)", method: "DELETE"))
    }

    /// A link the owner can open even when the upload is private or one-time.
    func ownerURL(for upload: UploadedFile, raw: Bool = false) -> URL {
        UploadLinks.signed(raw ? upload.rawURL : upload.url, id: upload.id, token: token, expires: Date().addingTimeInterval(3600))
    }

    // MARK: Plumbing

    private func request(_ path: String, method: String = "GET", headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL.appendingPathComponent("/"))!.absoluteURL)
        request.httpMethod = method
        request.timeoutInterval = 300
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private func send<Value: Decodable>(_ request: URLRequest) async throws -> Value {
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decode(data, response)
    }

    private func decode<Value: Decodable>(_ data: Data, _ response: URLResponse) throws -> Value {
        guard let http = response as? HTTPURLResponse else { throw UploadError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                ?? String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw UploadError.server(http.statusCode, message)
        }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw UploadError.invalidResponse
        }
    }
}

/// Reports how much of a request body has been sent.
private final class ProgressTracker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var total: Int64
    private let report: @Sendable (Double) -> Void

    init(total: Int64, report: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let expected = totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : total
        guard expected > 0 else { return }
        report(min(1, Double(totalBytesSent) / Double(expected)))
    }
}
