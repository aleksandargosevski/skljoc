import Foundation

/// Turns key presses into the text shown by "Show keystrokes": typing joins into words,
/// shortcuts like ⌘⇧4 show on their own, and a pause starts over.
public struct KeystrokeBuffer: Sendable {
    public private(set) var text = ""
    public var idleReset: TimeInterval = 1.5
    public var maxLength = 28

    private var lastInput: Date?
    private var lastWasShortcut = false

    public init() {}

    @discardableResult
    public mutating func register(keyCode: UInt32, characters: String?, modifiers: Shortcut.Modifiers, at date: Date = Date()) -> String {
        defer { lastInput = date }
        let expired = lastInput.map { date.timeIntervalSince($0) > idleReset } ?? true

        if !modifiers.isDisjoint(with: [.command, .control, .option]) {
            text = modifiers.symbols + Self.keyLabel(keyCode: keyCode, characters: nil)
            lastWasShortcut = true
            return text
        }

        let piece: String
        if let special = Self.specialKeys[keyCode] {
            piece = (modifiers.contains(.shift) ? "⇧" : "") + special
        } else if let characters, !characters.isEmpty, characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            piece = characters
        } else {
            piece = Self.keyLabel(keyCode: keyCode, characters: nil)
        }

        text = (expired || lastWasShortcut) ? piece : text + piece
        lastWasShortcut = false
        if text.count > maxLength { text = "…" + text.suffix(maxLength - 1) }
        return text
    }

    public mutating func clear() {
        text = ""
        lastInput = nil
        lastWasShortcut = false
    }

    private static let specialKeys: [UInt32: String] = [
        36: "↩", 76: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    private static func keyLabel(keyCode: UInt32, characters: String?) -> String {
        if keyCode == 49 { return "Space" }
        return specialKeys[keyCode] ?? KeyNames.name(for: keyCode) ?? characters?.uppercased() ?? "?"
    }
}
