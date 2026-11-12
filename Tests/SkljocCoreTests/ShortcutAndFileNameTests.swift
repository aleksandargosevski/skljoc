import Foundation
import Testing
@testable import SkljocCore

@Suite struct ShortcutTests {
    @Test func describesWithMacSymbols() {
        #expect(Shortcut.captureArea.description == "⇧⌘4")
        #expect(Shortcut(keyCode: 0, modifiers: [.control, .option]).description == "⌃⌥A")
    }

    @Test func globalShortcutsNeedARealModifier() {
        #expect(!Shortcut(keyCode: 0, modifiers: [.shift]).isValidGlobal)
        #expect(Shortcut(keyCode: 122, modifiers: []).isValidGlobal)
        #expect(Shortcut.captureFullscreen.isValidGlobal)
    }

    @Test func roundTripsEventFlags() {
        let modifiers: Shortcut.Modifiers = [.command, .shift]
        #expect(modifiers.eventFlags == 1_179_648)
        #expect(Shortcut.Modifiers(eventFlags: 1_179_648) == modifiers)
    }

    @Test func findsEnabledSystemScreenshotShortcut() {
        let hotKeys: [String: Any] = [
            "30": ["enabled": true, "value": ["parameters": [52, 21, 1_179_648], "type": "standard"]],
            "28": ["enabled": false, "value": ["parameters": [51, 20, 1_179_648], "type": "standard"]],
        ]
        #expect(SystemScreenshotShortcuts.conflict(for: .captureArea, in: hotKeys)?.name == "Save picture of selected area as a file")
        #expect(SystemScreenshotShortcuts.conflict(for: .captureFullscreen, in: hotKeys) == nil)
    }

    @Test func missingEntriesUseMacOSDefaults() {
        #expect(SystemScreenshotShortcuts.conflict(for: .captureFullscreen, in: [:]) != nil)
        #expect(SystemScreenshotShortcuts.conflict(for: .captureFullscreen, in: nil) != nil)
    }
}

@Suite struct CaptureFileNameTests {
    @Test func namesLikeMacOSScreenshots() {
        let date = Date(timeIntervalSince1970: 1_794_492_202) // 2026-11-12 14:03:22 UTC
        let name = CaptureFileName.make(date: date, format: .png, timeZone: TimeZone(identifier: "UTC")!)
        #expect(name == "Skljoc 2026-11-12 at 14.03.22.png")
    }

    @Test func avoidsOverwritingExistingFiles() {
        let folder = URL(fileURLWithPath: "/tmp/shots")
        let taken: Set<String> = ["/tmp/shots/a.png", "/tmp/shots/a (2).png"]
        let url = CaptureFileName.uniqueURL(in: folder, fileName: "a.png") { taken.contains($0.path) }
        #expect(url.lastPathComponent == "a (3).png")
    }
}
