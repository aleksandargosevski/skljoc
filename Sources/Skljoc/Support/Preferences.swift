import Foundation
import SkljocCore

/// Everything that has a global shortcut.
enum ShortcutAction: String, CaseIterable {
    case captureArea, captureFullscreen, captureText, captureAndPin, scrollingCapture, recordScreen, uploadFiles, shortenLink, shortenLinkNamed, library

    var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureFullscreen: "Capture Fullscreen"
        case .captureText: "Capture Text"
        case .captureAndPin: "Capture & Pin"
        case .scrollingCapture: "Scrolling Capture"
        case .recordScreen: "Record Screen"
        case .uploadFiles: "Upload Files"
        case .shortenLink: "Shorten Link in Clipboard"
        case .shortenLinkNamed: "Shorten Link…"
        case .library: "Library"
        }
    }

    var hotKeyID: UInt32 {
        switch self {
        case .captureArea: 1
        case .captureFullscreen: 2
        case .recordScreen: 3
        case .captureText: 4
        case .captureAndPin: 5
        case .scrollingCapture: 6
        case .library: 7
        case .shortenLink: 8
        case .uploadFiles: 9
        case .shortenLinkNamed: 10
        }
    }

    var defaultShortcut: Shortcut? {
        switch self {
        case .captureArea: .captureArea
        case .captureFullscreen: .captureFullscreen
        case .captureText: Shortcut(keyCode: 19, modifiers: [.command, .shift])
        case .captureAndPin: Shortcut(keyCode: 18, modifiers: [.command, .shift])
        case .scrollingCapture: Shortcut(keyCode: 22, modifiers: [.command, .shift])
        case .recordScreen: .recordScreen
        // ⌥⇧⌘L: ⇧⌘L alone belongs to Safari's sidebar and similar.
        case .shortenLink: Shortcut(keyCode: 37, modifiers: [.command, .shift, .option])
        case .uploadFiles: Shortcut(keyCode: 32, modifiers: [.command, .shift, .option])
        case .shortenLinkNamed: Shortcut(keyCode: 37, modifiers: [.command, .shift, .option, .control])
        // ⌥⇧⌘H: ⇧⌘H alone belongs to Finder's Home folder.
        case .library: Shortcut(keyCode: 4, modifiers: [.command, .shift, .option])
        }
    }

    fileprivate var defaultsKey: String {
        switch self {
        case .captureArea: "areaShortcut"
        case .captureFullscreen: "fullscreenShortcut"
        case .recordScreen: "recordShortcut"
        default: "\(rawValue)Shortcut"
        }
    }
}

/// How long screenshots and recordings stay in History.
enum HistoryRetention: String, CaseIterable {
    case week, month, thousandItems, forever

    var title: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .thousandItems: "Last 1000 items"
        case .forever: "Forever"
        }
    }

    func keeps(index: Int, date: Date, now: Date = Date()) -> Bool {
        switch self {
        case .week: now.timeIntervalSince(date) <= 7 * 86_400
        case .month: now.timeIntervalSince(date) <= 30 * 86_400
        case .thousandItems: index < 1000
        case .forever: true
        }
    }
}

/// Where the last recording area was, so the next recording starts there.
struct SavedRecordingArea: Codable, Equatable {
    var displayID: UInt32
    /// Points, relative to the top-left corner of that display.
    var rect: CGRect
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published private(set) var shortcuts: [ShortcutAction: Shortcut] = [:]
    @Published var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: Keys.saveFolder) } }
    @Published var format: ImageFormat { didSet { defaults.set(format.rawValue, forKey: Keys.format) } }
    @Published var exportAt1x: Bool { didSet { defaults.set(exportAt1x, forKey: Keys.exportAt1x) } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: Keys.playSound) } }

    @Published var recordingOptions: RecordingOptions { didSet { storeCodable(recordingOptions, key: Keys.recordingOptions) } }
    @Published var lastRecordingArea: SavedRecordingArea? { didSet { storeCodable(lastRecordingArea, key: Keys.lastRecordingArea) } }
    @Published var frameRate: Int { didSet { defaults.set(frameRate, forKey: Keys.frameRate) } }
    @Published var videoCodec: VideoCodec { didSet { defaults.set(videoCodec.rawValue, forKey: Keys.videoCodec) } }
    @Published var recordAt1x: Bool { didSet { defaults.set(recordAt1x, forKey: Keys.recordAt1x) } }
    @Published var showCursor: Bool { didSet { defaults.set(showCursor, forKey: Keys.showCursor) } }
    @Published var countdown: Bool { didSet { defaults.set(countdown, forKey: Keys.countdown) } }
    @Published var gifFrameRate: Int { didSet { defaults.set(gifFrameRate, forKey: Keys.gifFrameRate) } }
    @Published var gifMaxWidth: Int { didSet { defaults.set(gifMaxWidth, forKey: Keys.gifMaxWidth) } }
    @Published var historyRetention: HistoryRetention { didSet { defaults.set(historyRetention.rawValue, forKey: Keys.historyRetention) } }
    @Published var lastBackground: ScreenshotBackground? { didSet { storeCodable(lastBackground, key: Keys.lastBackground) } }
    @Published var autoScroll: Bool { didSet { defaults.set(autoScroll, forKey: Keys.autoScroll) } }
    /// The Worker's address, e.g. https://share.example.com. The token lives in the keychain.
    @Published var uploadBaseURL: String { didSet { defaults.set(uploadBaseURL, forKey: Keys.uploadBaseURL) } }
    @Published var uploadLinkFormat: UploadLinkFormat { didSet { defaults.set(uploadLinkFormat.rawValue, forKey: Keys.uploadLinkFormat) } }
    @Published var uploadExpiry: UploadExpiry { didSet { defaults.set(uploadExpiry.rawValue, forKey: Keys.uploadExpiry) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        saveFolder = defaults.string(forKey: Keys.saveFolder).map { URL(fileURLWithPath: $0) } ?? desktop
        format = defaults.string(forKey: Keys.format).flatMap(ImageFormat.init(rawValue:)) ?? .png
        exportAt1x = defaults.bool(forKey: Keys.exportAt1x)
        playSound = defaults.object(forKey: Keys.playSound) as? Bool ?? true

        recordingOptions = Self.loadCodable(Keys.recordingOptions, from: defaults) ?? RecordingOptions()
        lastRecordingArea = Self.loadCodable(Keys.lastRecordingArea, from: defaults)
        frameRate = defaults.object(forKey: Keys.frameRate) as? Int ?? 30
        videoCodec = defaults.string(forKey: Keys.videoCodec).flatMap(VideoCodec.init(rawValue:)) ?? .h264
        recordAt1x = defaults.bool(forKey: Keys.recordAt1x)
        showCursor = defaults.object(forKey: Keys.showCursor) as? Bool ?? true
        countdown = defaults.object(forKey: Keys.countdown) as? Bool ?? true
        gifFrameRate = defaults.object(forKey: Keys.gifFrameRate) as? Int ?? 15
        gifMaxWidth = defaults.object(forKey: Keys.gifMaxWidth) as? Int ?? 960
        historyRetention = defaults.string(forKey: Keys.historyRetention).flatMap(HistoryRetention.init(rawValue:)) ?? .month
        lastBackground = Self.loadCodable(Keys.lastBackground, from: defaults)
        autoScroll = defaults.object(forKey: Keys.autoScroll) as? Bool ?? true
        uploadBaseURL = defaults.string(forKey: Keys.uploadBaseURL) ?? ""
        uploadLinkFormat = defaults.string(forKey: Keys.uploadLinkFormat).flatMap(UploadLinkFormat.init(rawValue:)) ?? .page
        uploadExpiry = defaults.string(forKey: Keys.uploadExpiry).flatMap(UploadExpiry.init(rawValue:)) ?? .never

        Self.migrateHistoryShortcut(in: defaults)
        for action in ShortcutAction.allCases {
            shortcuts[action] = Self.loadShortcut(action, from: defaults)
        }
    }

    func shortcut(for action: ShortcutAction) -> Shortcut? {
        shortcuts[action]
    }

    /// A cleared shortcut is stored as empty data, so it doesn't come back as the default.
    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        shortcuts[action] = shortcut
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: action.defaultsKey)
    }

    private func storeCodable<Value: Encodable>(_ value: Value?, key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            NSLog("Skljoc: could not store preference \(key): \(error.localizedDescription)")
        }
    }

    private static func loadCodable<Value: Decodable>(_ key: String, from defaults: UserDefaults) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    /// Library used to be History, without a default shortcut. A shortcut someone picked for it carries over.
    private static func migrateHistoryShortcut(in defaults: UserDefaults) {
        let old = "historyShortcut"
        defer { defaults.removeObject(forKey: old) }
        guard let data = defaults.data(forKey: old), !data.isEmpty,
              defaults.data(forKey: ShortcutAction.library.defaultsKey) == nil else { return }
        defaults.set(data, forKey: ShortcutAction.library.defaultsKey)
    }

    private static func loadShortcut(_ action: ShortcutAction, from defaults: UserDefaults) -> Shortcut? {
        guard let data = defaults.data(forKey: action.defaultsKey) else { return action.defaultShortcut }
        if data.isEmpty { return nil }
        return (try? JSONDecoder().decode(Shortcut.self, from: data)) ?? action.defaultShortcut
    }

    private enum Keys {
        static let saveFolder = "saveFolder"
        static let format = "format"
        static let exportAt1x = "exportAt1x"
        static let playSound = "playSound"
        static let recordingOptions = "recordingOptions"
        static let lastRecordingArea = "lastRecordingArea"
        static let frameRate = "frameRate"
        static let videoCodec = "videoCodec"
        static let recordAt1x = "recordAt1x"
        static let showCursor = "showCursor"
        static let countdown = "countdown"
        static let gifFrameRate = "gifFrameRate"
        static let gifMaxWidth = "gifMaxWidth"
        static let historyRetention = "historyRetention"
        static let lastBackground = "lastBackground"
        static let autoScroll = "autoScroll"
        static let uploadBaseURL = "uploadBaseURL"
        static let uploadLinkFormat = "uploadLinkFormat"
        static let uploadExpiry = "uploadExpiry"
    }
}
