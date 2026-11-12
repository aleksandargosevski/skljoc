import AppKit
import Carbon.HIToolbox
import SkljocCore

/// System-wide shortcuts via Carbon hot keys, which need no Accessibility permission.
@MainActor
final class HotKeyCenter {
    enum Registration: Equatable {
        case registered
        case cleared
        case invalid
        /// One of the macOS screenshot shortcuts still uses this combination.
        case takenBySystem(String)
        /// Another app (often CleanShot) registered it first.
        case takenByOtherApp
    }

    private struct Entry {
        var shortcut: Shortcut
        var ref: EventHotKeyRef?
        var action: () -> Void
    }

    private var entries: [UInt32: Entry] = [:]
    private var handlerRef: EventHandlerRef?
    private var isSuspended = false
    private static let signature = OSType(0x534B_4C4A) // "SKLJ"

    @discardableResult
    func register(id: UInt32, shortcut: Shortcut?, action: @escaping () -> Void) -> Registration {
        unregister(id: id)
        guard let shortcut else { return .cleared }
        guard shortcut.isValidGlobal else { return .invalid }
        if let conflict = SystemScreenshotShortcuts.conflict(for: shortcut, in: Self.symbolicHotKeys()) {
            return .takenBySystem(conflict.name)
        }

        installHandlerIfNeeded()
        var entry = Entry(shortcut: shortcut, ref: nil, action: action)
        if !isSuspended {
            guard let ref = Self.registerCarbon(shortcut, id: id) else { return .takenByOtherApp }
            entry.ref = ref
        }
        entries[id] = entry
        return .registered
    }

    /// For short-lived keys like Esc while the pointer is over a preview, which skip the global-shortcut rules.
    func registerTransient(id: UInt32, shortcut: Shortcut, action: @escaping () -> Void) {
        unregister(id: id)
        installHandlerIfNeeded()
        let ref = isSuspended ? nil : Self.registerCarbon(shortcut, id: id)
        entries[id] = Entry(shortcut: shortcut, ref: ref, action: action)
    }

    func unregister(id: UInt32) {
        if let ref = entries[id]?.ref { UnregisterEventHotKey(ref) }
        entries[id] = nil
    }

    /// Lets a shortcut recorder see key presses that are currently global shortcuts.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        for id in entries.keys {
            if let ref = entries[id]?.ref { UnregisterEventHotKey(ref) }
            entries[id]?.ref = nil
        }
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        for (id, entry) in entries {
            entries[id]?.ref = Self.registerCarbon(entry.shortcut, id: id)
        }
    }

    private func handle(id: UInt32) {
        entries[id]?.action()
    }

    private static func symbolicHotKeys() -> [String: Any]? {
        UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
    }

    private static func registerCarbon(_ shortcut: Shortcut, id: UInt32) -> EventHotKeyRef? {
        var modifiers: UInt32 = 0
        if shortcut.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if shortcut.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if shortcut.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        if shortcut.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(shortcut.keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? ref : nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == HotKeyCenter.signature else { return noErr }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { center.handle(id: hotKeyID.id) } }
            return noErr
        }, 1, &spec, context, &handlerRef)
    }
}
