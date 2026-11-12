import Foundation

/// The pure parts of setting up the Worker through the Cloudflare API.
public enum CloudflareSetup {
    /// Opens Cloudflare's "Create API token" page with exactly the permissions Škljoc needs already picked:
    /// Workers Scripts, R2 and D1 to edit, and zones to read (to find the domain).
    public static var tokenTemplateURL: URL {
        let permissions = #"[{"key":"workers_scripts","type":"edit"},{"key":"workers_r2","type":"edit"},{"key":"d1","type":"edit"},{"key":"zone","type":"read"}]"#
        var components = URLComponents(string: "https://dash.cloudflare.com/profile/api-tokens")!
        components.queryItems = [
            URLQueryItem(name: "permissionGroupKeys", value: permissions),
            URLQueryItem(name: "accountId", value: "*"),
            URLQueryItem(name: "zoneId", value: "all"),
            URLQueryItem(name: "name", value: "Škljoc"),
        ]
        return components.url!
    }

    /// Zones that could hold `hostname`, most specific first: share.example.com, then example.com.
    public static func zoneCandidates(for hostname: String) -> [String] {
        let labels = hostname.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return [] }
        return (0...(labels.count - 2)).map { labels[$0...].joined(separator: ".") }
    }

    /// A hostname typed by the user, without scheme, path or trailing dot. Nil when it can't be one.
    public static func normalizedHostname(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = value.range(of: "://") { value = String(value[range.upperBound...]) }
        value = String(value.split(separator: "/").first ?? "")
        if value.hasSuffix(".") { value.removeLast() }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        let valid = labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
                && label.first != "-" && label.last != "-"
        }
        return valid ? value : nil
    }

    /// Migrations not applied yet, in file-name order (0001_…, 0002_…).
    public static func pendingMigrations(available: [String], applied: [String]) -> [String] {
        let done = Set(applied)
        return available.filter { !done.contains($0) }.sorted()
    }

    /// The version the bundled Worker reports from /api/health, read from `export const VERSION = 1;`.
    public static func workerVersion(inSource source: String) -> Int? {
        guard let range = source.range(of: #"export const VERSION = (\d+);"#, options: .regularExpression) else { return nil }
        return Int(source[range].filter(\.isNumber))
    }

    /// The SQL that applies one migration and records it the way Wrangler does, so `wrangler d1 migrations` agrees.
    public static func migrationBatch(name: String, sql: String) -> String {
        let escaped = name.replacingOccurrences(of: "'", with: "''")
        return """
        CREATE TABLE IF NOT EXISTS d1_migrations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL);
        \(sql.trimmingCharacters(in: .whitespacesAndNewlines))
        INSERT INTO d1_migrations (name) VALUES ('\(escaped)');
        """
    }
}
