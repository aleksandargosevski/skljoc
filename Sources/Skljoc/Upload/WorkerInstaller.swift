import AppKit
import SkljocCore

enum WorkerInstallError: LocalizedError {
    case missingWorkerFiles
    case noAccount
    case zoneNotFound(String)
    case noWorkersDevSubdomain
    case r2NotEnabled

    var errorDescription: String? {
        switch self {
        case .missingWorkerFiles:
            "This copy of Škljoc doesn't include the Worker. Build it with scripts/build.sh."
        case .noAccount:
            "The API token doesn't give access to any Cloudflare account."
        case .zoneNotFound(let host):
            "“\(host)” isn't a domain in your Cloudflare account. Add the domain to Cloudflare first, or leave the field empty to use workers.dev."
        case .noWorkersDevSubdomain:
            "Your account has no workers.dev subdomain yet. Open Workers & Pages in the Cloudflare dashboard once, or enter your own domain."
        case .r2NotEnabled:
            "R2 isn't turned on for your account yet. Open R2 in the Cloudflare dashboard once to enable it (the free plan is enough), then try again."
        }
    }
}

/// Sets up (or updates) the Škljoc Worker on the user's Cloudflare account with the Worker bundled in the app:
/// R2 bucket, D1 database and migrations, the Worker itself with its upload token, the hourly cleanup, and the domain.
@MainActor
final class WorkerInstaller: ObservableObject {
    struct Step: Identifiable {
        enum State { case running, done, failed }
        let id = UUID()
        var title: String
        var state: State
    }

    struct Result {
        var address: URL
        /// Nil when the Worker kept the token it already had.
        var uploadToken: String?
    }

    static let keychainAccount = "cloudflare"

    @Published var apiToken = ""
    @Published var domain = ""
    @Published private(set) var steps: [Step] = []
    @Published private(set) var isRunning = false
    @Published private(set) var errorText: String?
    /// Something to know that isn't a failure, like a new domain still coming online.
    @Published private(set) var notice: String?

    var workerName = "skljoc"
    var bucketName = "skljoc"
    var databaseName = "skljoc"

    /// The Worker files copied into the app by scripts/build.sh.
    static var bundledWorker: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Worker", isDirectory: true)
    }

    static var bundledVersion: Int? {
        guard let folder = bundledWorker,
              let source = try? String(contentsOf: folder.appendingPathComponent("src/api.js"), encoding: .utf8) else { return nil }
        return CloudflareSetup.workerVersion(inSource: source)
    }

    /// `keepToken` keeps the Worker's current upload token (when it has one), so other Macs keep working.
    func install(keepToken: Bool) async -> Result? {
        guard !isRunning else { return nil }
        isRunning = true
        errorText = nil
        notice = nil
        steps = []
        defer { isRunning = false }
        do {
            return try await run(keepToken: keepToken)
        } catch {
            if let index = steps.indices.last { steps[index].state = .failed }
            errorText = error.localizedDescription
            NSLog("Skljoc: Cloudflare setup failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func run(keepToken: Bool) async throws -> Result {
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let api = CloudflareAPI(token: token)
        guard let folder = Self.bundledWorker,
              let modules = try? Self.modules(in: folder.appendingPathComponent("src")), !modules.isEmpty else {
            throw WorkerInstallError.missingWorkerFiles
        }
        let hostname = CloudflareSetup.normalizedHostname(domain)

        // Account, and the zone when a domain is given (its account wins when there are several).
        begin("Checking your Cloudflare account")
        var zone: CloudflareAPI.Zone?
        if let hostname {
            for candidate in CloudflareSetup.zoneCandidates(for: hostname) {
                if let found = try await api.zone(named: candidate) {
                    zone = found
                    break
                }
            }
            guard zone != nil else { throw WorkerInstallError.zoneNotFound(hostname) }
        }
        let accounts = try await api.accounts()
        guard let account = zone?.account.id ?? accounts.first?.id else { throw WorkerInstallError.noAccount }
        // Saved so "Update Worker" works later without pasting it again.
        try? Keychain.setToken(token, for: Self.keychainAccount)
        finish()

        begin("R2 bucket “\(bucketName)”")
        do {
            if try await !api.bucketExists(bucketName, account: account) {
                try await api.createBucket(bucketName, account: account)
            }
        } catch let error as CloudflareError where error.codes.contains(10042) {
            throw WorkerInstallError.r2NotEnabled
        }
        finish()

        begin("D1 database “\(databaseName)”")
        let existingDatabase = try await api.database(named: databaseName, account: account)
        let database = if let existingDatabase { existingDatabase } else { try await api.createDatabase(databaseName, account: account) }
        try await applyMigrations(api: api, folder: folder.appendingPathComponent("migrations"), database: database.uuid, account: account)
        finish()

        begin("Deploying the Worker")
        let exists = try await api.scriptExists(workerName, account: account)
        var uploadToken: String?
        var bindings: [[String: Any]] = [
            ["type": "r2_bucket", "name": "BUCKET", "bucket_name": bucketName],
            ["type": "d1", "name": "DB", "id": database.uuid],
        ]
        var keep: [String] = []
        if exists {
            // Names and the home page stay as they were set.
            keep.append("plain_text")
        } else {
            bindings.append(["type": "plain_text", "name": "SITE_NAME", "text": "Škljoc"])
            bindings.append(["type": "plain_text", "name": "HOME_URL", "text": ""])
        }
        if exists && keepToken {
            keep.append("secret_text")
        } else {
            let newToken = Self.randomToken()
            bindings.append(["type": "secret_text", "name": "UPLOAD_TOKEN", "text": newToken])
            uploadToken = newToken
        }
        var metadata: [String: Any] = [
            "main_module": "index.js",
            "compatibility_date": "2026-11-12",
            "bindings": bindings,
        ]
        if !keep.isEmpty { metadata["keep_bindings"] = keep }
        try await api.uploadScript(workerName, account: account, metadata: metadata, modules: modules)
        try await api.setSchedules(["17 * * * *"], script: workerName, account: account)
        finish()

        let address: URL
        if let hostname, let zone {
            begin("Connecting \(hostname)")
            try await api.attachDomain(hostname, zone: zone.id, script: workerName, account: account)
            address = URL(string: "https://\(hostname)")!
        } else {
            begin("Turning on workers.dev")
            guard let subdomain = try await api.workersSubdomain(account: account) else { throw WorkerInstallError.noWorkersDevSubdomain }
            try await api.enableWorkersDev(script: workerName, account: account)
            address = URL(string: "https://\(workerName).\(subdomain).workers.dev")!
        }
        finish()

        begin("Checking that it answers")
        if let uploadToken {
            do {
                try await waitForHealth(UploadClient(baseURL: address, token: uploadToken), attempts: hostname == nil ? 20 : 8)
            } catch {
                // New hostnames need a few minutes for DNS and the certificate; the setup itself is complete.
                guard hostname != nil else { throw error }
                notice = "\(address.host() ?? "The domain") can take a few minutes (on some networks up to half an hour) to start working on this Mac. Use Test Connection in a little while."
            }
        }
        finish()
        return Result(address: address, uploadToken: uploadToken)
    }

    private func applyMigrations(api: CloudflareAPI, folder: URL, database: String, account: String) async throws {
        let files = (try FileManager.default.contentsOfDirectory(atPath: folder.path)).filter { $0.hasSuffix(".sql") }
        let table = try await api.query(
            "CREATE TABLE IF NOT EXISTS d1_migrations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL); SELECT name FROM d1_migrations",
            database: database, account: account
        )
        let applied = table.compactMap(\.results).flatMap { $0 }.compactMap { $0["name"]?.string }
        for name in CloudflareSetup.pendingMigrations(available: files, applied: applied) {
            let sql = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            _ = try await api.query(CloudflareSetup.migrationBatch(name: name, sql: sql), database: database, account: account)
        }
    }

    /// A fresh custom domain or workers.dev name can take a little while before it answers.
    private func waitForHealth(_ client: UploadClient, attempts: Int) async throws {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                _ = try await client.health()
                return
            } catch {
                lastError = error
                try await Task.sleep(for: .seconds(attempt < 5 ? 2 : 4))
            }
        }
        throw lastError ?? UploadError.invalidResponse
    }

    private func begin(_ title: String) {
        steps.append(Step(title: title, state: .running))
    }

    private func finish() {
        if let index = steps.indices.last { steps[index].state = .done }
    }

    private static func modules(in folder: URL) throws -> [(name: String, source: Data)] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".js") }
            .sorted()
            .map { ($0, try Data(contentsOf: folder.appendingPathComponent($0))) }
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
