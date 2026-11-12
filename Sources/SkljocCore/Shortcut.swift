import Foundation

/// A global keyboard shortcut, stored by virtual key code so it doesn't depend on the keyboard layout.
public struct Shortcut: Codable, Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        /// The values NSEvent.ModifierFlags uses, which is also how macOS stores its own shortcuts.
        public var eventFlags: UInt {
            var flags: UInt = 0
            if contains(.shift) { flags |= 1 << 17 }
            if contains(.control) { flags |= 1 << 18 }
            if contains(.option) { flags |= 1 << 19 }
            if contains(.command) { flags |= 1 << 20 }
            return flags
        }

        public init(eventFlags: UInt) {
            var modifiers: Modifiers = []
            if eventFlags & (1 << 17) != 0 { modifiers.insert(.shift) }
            if eventFlags & (1 << 18) != 0 { modifiers.insert(.control) }
            if eventFlags & (1 << 19) != 0 { modifiers.insert(.option) }
            if eventFlags & (1 << 20) != 0 { modifiers.insert(.command) }
            self = modifiers
        }

        public var symbols: String {
            (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
                + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
        }
    }

    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let captureArea = Shortcut(keyCode: KeyNames.digit4, modifiers: [.command, .shift])
    public static let captureFullscreen = Shortcut(keyCode: KeyNames.digit3, modifiers: [.command, .shift])
    public static let recordScreen = Shortcut(keyCode: KeyNames.digit5, modifiers: [.command, .shift])

    /// Global shortcuts need ⌘, ⌃ or ⌥; with only ⇧ they would swallow normal typing.
    public var isValidGlobal: Bool {
        !modifiers.isDisjoint(with: [.command, .control, .option]) || KeyNames.isFunctionKey(keyCode)
    }

    public var keyName: String { KeyNames.name(for: keyCode) ?? "Key \(keyCode)" }

    public var description: String { modifiers.symbols + keyName }
}

public enum KeyNames {
    public static let digit3: UInt32 = 20
    public static let digit4: UInt32 = 21
    public static let digit5: UInt32 = 23
    public static let escape: UInt32 = 53

    public static func name(for keyCode: UInt32) -> String? {
        names[keyCode]
    }

    /// The character a menu item shows for its key equivalent, for keys that have one.
    public static func menuCharacter(for keyCode: UInt32) -> String? {
        guard let name = names[keyCode], name.count == 1 else { return nil }
        return name.lowercased()
    }

    public static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        names[keyCode]?.hasPrefix("F") == true && (names[keyCode]?.count ?? 0) > 1
    }

    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 107: "F14",
        109: "F10", 111: "F12", 113: "F15", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2",
        121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

/// The macOS screenshot shortcuts (System Settings → Keyboard → Keyboard Shortcuts → Screenshots).
public enum SystemScreenshotShortcuts {
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var shortcut: Shortcut
    }

    /// Identifiers in com.apple.symbolichotkeys with the shortcuts macOS uses when an entry is missing.
    static let known: [(id: String, name: String, shortcut: Shortcut)] = [
        ("28", "Save picture of screen as a file", Shortcut(keyCode: 20, modifiers: [.command, .shift])),
        ("29", "Copy picture of screen to the clipboard", Shortcut(keyCode: 20, modifiers: [.command, .shift, .control])),
        ("30", "Save picture of selected area as a file", Shortcut(keyCode: 21, modifiers: [.command, .shift])),
        ("31", "Copy picture of selected area to the clipboard", Shortcut(keyCode: 21, modifiers: [.command, .shift, .control])),
        ("184", "Screenshot and recording options", Shortcut(keyCode: 23, modifiers: [.command, .shift])),
    ]

    /// The enabled screenshot shortcuts, read from the `AppleSymbolicHotKeys` dictionary.
    public static func enabled(in symbolicHotKeys: [String: Any]?) -> [Entry] {
        known.compactMap { id, name, fallback in
            guard let entry = symbolicHotKeys?[id] as? [String: Any] else {
                return Entry(name: name, shortcut: fallback)
            }
            guard (entry["enabled"] as? NSNumber)?.boolValue ?? (entry["enabled"] as? Bool) ?? true else { return nil }
            let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Any]
            guard let parameters, parameters.count >= 3,
                  let keyCode = (parameters[1] as? NSNumber)?.uint32Value,
                  let flags = (parameters[2] as? NSNumber)?.uintValue else {
                return Entry(name: name, shortcut: fallback)
            }
            return Entry(name: name, shortcut: Shortcut(keyCode: keyCode, modifiers: .init(eventFlags: flags)))
        }
    }

    public static func conflict(for shortcut: Shortcut, in symbolicHotKeys: [String: Any]?) -> Entry? {
        enabled(in: symbolicHotKeys).first { $0.shortcut == shortcut }
    }
}
