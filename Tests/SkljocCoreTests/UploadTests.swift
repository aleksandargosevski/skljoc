import Foundation
import Testing
@testable import SkljocCore

@Suite struct UploadTests {
    @Test func signsLinksLikeTheWorker() {
        // Same as: printf 'view.aB3x9KqZ.1800000000' | openssl dgst -sha256 -hmac secret
        let url = UploadLinks.signed(
            URL(string: "https://share.example.com/aB3x9KqZ")!,
            id: "aB3x9KqZ", token: "secret", expires: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let expected = "ac9a8ce38cd6f5a0c771dad19f5c4b157295f68ec6a3b9ca95274f87b9611684"
        let signature = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "sig" }?.value
        #expect(url.absoluteString.hasPrefix("https://share.example.com/aB3x9KqZ?exp=1800000000&sig="))
        #expect(signature == expected)
    }

    @Test func normalizesWorkerAddresses() {
        #expect(UploadLinks.normalizedBase("share.example.com/")?.absoluteString == "https://share.example.com")
        #expect(UploadLinks.normalizedBase(" https://share.example.com/some/path ")?.absoluteString == "https://share.example.com")
        #expect(UploadLinks.normalizedBase("http://localhost:8787")?.absoluteString == "http://localhost:8787")
        #expect(UploadLinks.normalizedBase("") == nil)
        #expect(UploadLinks.normalizedBase("ftp://x") == nil)
    }

    @Test func splitsLargeFilesIntoParts() {
        let parts = UploadParts.plan(fileSize: 120, partSize: 50)
        #expect(parts.map(\.length) == [50, 50, 20])
        #expect(parts.map(\.number) == [1, 2, 3])
        #expect(parts.last?.offset == 100)
        #expect(UploadParts.plan(fileSize: 0).isEmpty)
    }

    @Test func optionsBecomeTheWorkerHeader() throws {
        var options = UploadOptions()
        options.isPrivate = true
        options.expiry = .day
        let header = try UploadOptions.headerValue(options.payload(width: 800, height: 600))
        #expect(!header.contains("=") && !header.contains("+") && !header.contains("/"))
        var base64 = header.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        let data = try #require(Data(base64Encoded: base64))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["private"] as? Bool == true)
        #expect(json["expiresIn"] as? Int == 86_400)
        #expect(json["password"] is NSNull)
        #expect(json["width"] as? Int == 800)
    }

    @Test func decodesTheWorkerResponse() throws {
        let json = #"{"id":"aB3x9KqZ","url":"https://s.example.com/aB3x9KqZ","rawUrl":"https://s.example.com/aB3x9KqZ.png","filename":"Shot.png","contentType":"image/png","size":10,"width":800,"height":600,"duration":null,"createdAt":1800000000,"expiresAt":null,"private":false,"hasPassword":false,"burn":false,"burnedAt":null,"views":3,"lastViewedAt":null,"hasPoster":false}"#
        let upload = try JSONDecoder().decode(UploadedFile.self, from: Data(json.utf8))
        #expect(upload.views == 3)
        #expect(UploadLinkFormat.markdown.text(for: upload) == "![Shot.png](https://s.example.com/aB3x9KqZ.png)")
    }
}
