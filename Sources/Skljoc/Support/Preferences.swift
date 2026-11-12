import Foundation
import SkljocCore

/// Everything that has a global shortcut.
enum ShortcutAction: String, CaseIterable {
    case captureArea, captureFullscreen, recordScreen

    var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureFullscreen: "Capture Fullscreen"
        case .recordScreen: "Record Screen"
        }
    }

    var hotKeyID: UInt32 {
        switch self {
        case .captureArea: 1
        case .captureFullscreen: 2
        case .recordScreen: 3
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .captureArea: .captureArea
        case .captureFullscreen: .captureFullscreen
        case .recordScreen: .recordScreen
        }
    }

    fileprivate var defaultsKey: String {
        switch self {
        case .captureArea: "areaShortcut"
        case .captureFullscreen: "fullscreenShortcut"
        case .recordScreen: "recordShortcut"
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
    }
}
