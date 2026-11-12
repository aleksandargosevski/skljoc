import CryptoKit
import Foundation

/// How long an uploaded link works.
public enum UploadExpiry: String, Codable, CaseIterable, Sendable {
    case never, hour, day, week, month

    public var title: String {
        switch self {
        case .never: "Never"
        case .hour: "1 hour"
        case .day: "1 day"
        case .week: "7 days"
        case .month: "30 days"
        }
    }

    public var seconds: Int? {
        switch self {
        case .never: nil
        case .hour: 3600
        case .day: 86_400
        case .week: 604_800
        case .month: 2_592_000
        }
    }
}

/// What goes to the clipboard after an upload.
public enum UploadLinkFormat: String, Codable, CaseIterable, Sendable {
    case page, raw, markdown

    public var title: String {
        switch self {
        case .page: "Link to the page"
        case .raw: "Direct link to the file"
        case .markdown: "Markdown image"
        }
    }

    public func text(for upload: UploadedFile) -> String {
        switch self {
        case .page: upload.url.absoluteString
        case .raw: upload.rawURL.absoluteString
        case .markdown:
            upload.contentType.hasPrefix("video/")
                ? "[\(upload.filename)](\(upload.url.absoluteString))"
                : "![\(upload.filename)](\(upload.rawURL.absoluteString))"
        }
    }
}

/// Per-upload settings, sent to the Worker as base64url JSON in `X-Skljoc-Options`.
public struct UploadOptions: Codable, Equatable, Sendable {
    public var isPrivate = false
    public var password: String?
    public var expiry: UploadExpiry = .never
    public var burnAfterViewing = false

    public init() {}

    /// The JSON the Worker expects. Unset fields are sent explicitly so editing options can also clear them.
    public func payload(width: Int? = nil, height: Int? = nil, duration: Double? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "private": isPrivate,
            "burn": burnAfterViewing,
            "password": password.flatMap { $0.isEmpty ? nil : $0 } ?? NSNull(),
            "expiresIn": expiry.seconds ?? NSNull(),
        ]
        if let width { payload["width"] = width }
        if let height { payload["height"] = height }
        if let duration { payload["duration"] = duration }
        return payload
    }

    public static func headerValue(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// An upload as the Worker describes it.
public struct UploadedFile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var url: URL
    public var rawURL: URL
    public var filename: String
    public var contentType: String
    public var size: Int
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var createdAt: Int
    public var expiresAt: Int?
    public var isPrivate: Bool
    public var hasPassword: Bool
    public var burn: Bool
    public var burnedAt: Int?
    public var views: Int
    public var lastViewedAt: Int?
    public var hasPoster: Bool

    enum CodingKeys: String, CodingKey {
        case id, url, filename, contentType, size, width, height, duration, createdAt, expiresAt
        case hasPassword, burn, burnedAt, views, lastViewedAt, hasPoster
        case rawURL = "rawUrl"
        case isPrivate = "private"
    }

    public var isVideo: Bool { contentType.hasPrefix("video/") }
    public var createdDate: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }
    public var expiresDate: Date? { expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

public enum UploadLinks {
    /// A link to a private (or one-time) upload that works for its owner until `expires`.
    /// Matches the Worker: HMAC-SHA256(token, "view.<id>.<expires>") in hex.
    public static func signed(_ url: URL, id: String, token: String, expires: Date) -> URL {
        let seconds = Int(expires.timeIntervalSince1970)
        let key = SymmetricKey(data: Data(token.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data("view.\(id).\(seconds)".utf8), using: key)
            .map { String(format: "%02x", $0) }
            .joined()
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "exp", value: String(seconds)), URLQueryItem(name: "sig", value: signature)]
        return components?.url ?? url
    }

    /// The Worker's address from whatever was typed: adds https:// and drops trailing slashes and paths.
    public static func normalizedBase(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard var components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty,
              components.scheme == "https" || components.scheme == "http" else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

/// A redirect on the Worker, made by the URL shortener.
public struct ShortLink: Codable, Equatable, Sendable {
    public var id: String
    public var url: URL
    public var targetURL: URL

    enum CodingKeys: String, CodingKey {
        case id, url
        case targetURL = "targetUrl"
    }
}

public enum LinkShortening {
    public enum Outcome: Equatable, Sendable {
        case shorten(URL)
        case notALink
        /// Already one of the Worker's own links, so shortening it again makes no sense.
        case alreadyShort(URL)
    }

    /// Decides what to do with the clipboard text: only a single http(s) URL with a real host gets shortened.
    public static func check(_ text: String?, workerBase: URL?) -> Outcome {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), isRealHost(host) else {
            return .notALink
        }
        if let workerHost = workerBase?.host(percentEncoded: false), host.lowercased() == workerHost.lowercased() {
            return .alreadyShort(url)
        }
        return .shorten(url)
    }

    private static func isRealHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty } && (labels.last?.count ?? 0) >= 2
    }
}

/// How a file is split for multipart uploads: equal parts (R2 needs at least 5 MB each), the last one shorter.
public enum UploadParts {
    /// Files up to this size go in one request; Cloudflare accepts up to 100 MB per request on most plans.
    public static let singleRequestLimit = 90 * 1024 * 1024
    public static let partSize = 50 * 1024 * 1024

    public struct Part: Equatable, Sendable {
        public var number: Int
        public var offset: Int
        public var length: Int
    }

    public static func plan(fileSize: Int, partSize: Int = partSize) -> [Part] {
        guard fileSize > 0, partSize > 0 else { return [] }
        return stride(from: 0, to: fileSize, by: partSize).enumerated().map { index, offset in
            Part(number: index + 1, offset: offset, length: min(partSize, fileSize - offset))
        }
    }
}
