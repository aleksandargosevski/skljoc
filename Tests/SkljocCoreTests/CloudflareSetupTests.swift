import Foundation
import Testing
@testable import SkljocCore

@Suite struct CloudflareSetupTests {
    @Test func findsZonesForSubdomains() {
        #expect(CloudflareSetup.zoneCandidates(for: "share.example.co.uk") == ["share.example.co.uk", "example.co.uk", "co.uk"])
        #expect(CloudflareSetup.zoneCandidates(for: "gosev.ski") == ["gosev.ski"])
        #expect(CloudflareSetup.zoneCandidates(for: "localhost").isEmpty)
    }

    @Test func cleansUpTypedHostnames() {
        #expect(CloudflareSetup.normalizedHostname(" https://Share.Example.com/path ") == "share.example.com")
        #expect(CloudflareSetup.normalizedHostname("gosev.ski.") == "gosev.ski")
        #expect(CloudflareSetup.normalizedHostname("not a domain") == nil)
        #expect(CloudflareSetup.normalizedHostname("-bad.com") == nil)
        #expect(CloudflareSetup.normalizedHostname("") == nil)
    }

    @Test func runsOnlyMissingMigrationsInOrder() {
        let pending = CloudflareSetup.pendingMigrations(
            available: ["0002_more.sql", "0001_links.sql", "0003_last.sql"],
            applied: ["0001_links.sql"]
        )
        #expect(pending == ["0002_more.sql", "0003_last.sql"])
    }

    @Test func readsTheBundledWorkerVersion() {
        #expect(CloudflareSetup.workerVersion(inSource: "import x;\nexport const VERSION = 12;\n") == 12)
        #expect(CloudflareSetup.workerVersion(inSource: "nothing here") == nil)
    }

    @Test func recordsMigrationsLikeWrangler() {
        let batch = CloudflareSetup.migrationBatch(name: "0001_links.sql", sql: "CREATE TABLE links (id TEXT);\n")
        #expect(batch.contains("CREATE TABLE IF NOT EXISTS d1_migrations"))
        #expect(batch.contains("CREATE TABLE links (id TEXT);"))
        #expect(batch.hasSuffix("INSERT INTO d1_migrations (name) VALUES ('0001_links.sql');"))
    }

    @Test func tokenTemplateAsksForTheRightPermissions() {
        let query = URLComponents(url: CloudflareSetup.tokenTemplateURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let permissions = query.first { $0.name == "permissionGroupKeys" }?.value ?? ""
        for key in ["workers_scripts", "workers_r2", "d1", "zone"] {
            #expect(permissions.contains("\"\(key)\""))
        }
        #expect(query.first { $0.name == "accountId" }?.value == "*")
    }
}
