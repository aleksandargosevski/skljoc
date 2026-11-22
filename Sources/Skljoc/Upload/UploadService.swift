import AppKit
@preconcurrency import AVFoundation
import CryptoKit
import SkljocCore

/// What was uploaded for a screenshot or recording, kept next to it so the same version isn't uploaded twice.
struct UploadRecord: Codable {
    var upload: UploadedFile
    /// Changes when the edits or the export format change.
    var fingerprint: String
    var options: UploadOptions
}

/// Uploads screenshots and recordings to the user's own Worker.
@MainActor
final class UploadService {
    static let keychainAccount = "default"

    private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    var client: UploadClient? {
        guard let base = UploadLinks.normalizedBase(preferences.uploadBaseURL),
              let token = Keychain.token(for: Self.keychainAccount), !token.isEmpty else { return nil }
        return UploadClient(baseURL: base, token: token)
    }

    var isConfigured: Bool { client != nil }

    /// Shown before a link name, e.g. "gosev.ski/".
    var linkPrefix: String? {
        UploadLinks.normalizedBase(preferences.uploadBaseURL).map { "\($0.host() ?? $0.absoluteString)/" }
    }

    /// Why `slug` can't be used for a new link, or nil when it is free.
    func nameProblem(_ slug: String) async -> String? {
        guard let client else { return UploadError.notConfigured.localizedDescription }
        do {
            return try await client.isAvailable(slug) ? nil : "\(linkPrefix ?? "")\(slug) is already taken."
        } catch {
            return error.localizedDescription
        }
    }

    var defaultOptions: UploadOptions {
        var options = UploadOptions()
        options.expiry = preferences.uploadExpiry
        return options
    }

    /// Uploads (or reuses an earlier upload of the same version), then returns it.
    func upload(
        file: URL, sideFileOf mediaURL: URL, fingerprint: String, contentType: String,
        media: (width: Int?, height: Int?, duration: Double?), poster: CGImage? = nil,
        options: UploadOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UploadedFile {
        guard let client else { throw UploadError.notConfigured }
        let recordURL = Self.recordURL(for: mediaURL)

        if let record = MediaFiles.read(UploadRecord.self, from: recordURL), record.fingerprint == fingerprint,
           let current = try? await client.update(record.upload.id, options: options.payload()) {
            try? MediaFiles.write(UploadRecord(upload: current, fingerprint: fingerprint, options: options), to: recordURL)
            return current
        }

        let upload = try await client.upload(
            file, filename: file.lastPathComponent, contentType: contentType,
            options: options.payload(width: media.width, height: media.height, duration: media.duration),
            progress: progress
        )
        if let poster, let jpeg = NSBitmapImageRep(cgImage: poster).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            do {
                try await client.setPoster(jpeg, for: upload.id)
            } catch {
                NSLog("Skljoc: could not upload the video poster: \(error.localizedDescription)")
            }
        }
        do {
            try MediaFiles.write(UploadRecord(upload: upload, fingerprint: fingerprint, options: options), to: recordURL)
        } catch {
            NSLog("Skljoc: could not remember the upload: \(error.localizedDescription)")
        }
        return upload
    }

    /// Puts the link on the clipboard in the chosen format. Private and one-time uploads get an owner link instead,
    /// since the public link wouldn't open for anyone.
    func copyLink(for upload: UploadedFile) -> String {
        let text = linkText(for: upload)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return text
    }

    func linkText(for upload: UploadedFile) -> String {
        if upload.isPrivate, let client { return client.ownerURL(for: upload).absoluteString }
        return preferences.uploadLinkFormat.text(for: upload)
    }

    static func recordURL(for mediaURL: URL) -> URL {
        mediaURL.deletingLastPathComponent().appendingPathComponent("\(MediaFiles.baseName(of: mediaURL)).upload.json")
    }

    static func fingerprint(_ parts: [any Encodable]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = parts.compactMap { try? encoder.encode(AnyEncodable($0)) }.reduce(Data(), +)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func posterFrame(of url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        return try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
