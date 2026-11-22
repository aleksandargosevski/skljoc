import AppKit
import Combine
import SkljocCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let coordinator = AppCoordinator()
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var stateSubscription: AnyCancellable?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.delegate = self
        statusItem = item
        showIdleIcon()

        NSApp.mainMenu = Self.makeMainMenu()
        coordinator.start()
        stateSubscription = coordinator.recorder.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.recordingStateChanged(state) }
    }

    // MARK: Status item

    @objc private func statusItemClicked() {
        let recorder = coordinator.recorder
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if (recorder.state == .recording || recorder.state == .paused) && !isRightClick {
            recorder.stop()
            return
        }
        showMenu()
    }

    private func showMenu() {
        guard let statusItem else { return }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func recordingStateChanged(_ state: RecordingController.State) {
        timer?.invalidate()
        timer = nil
        switch state {
        case .recording, .paused:
            updateRecordingTitle()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRecordingTitle() }
            }
        case .finishing:
            statusItem?.button?.title = " …"
        default:
            showIdleIcon()
        }
    }

    private func showIdleIcon() {
        let image = Bundle.main.image(forResource: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Škljoc")
        image?.size = CGSize(width: 18, height: 18)
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.title = ""
        statusItem?.button?.toolTip = "Škljoc"
    }

    private func updateRecordingTitle() {
        let recorder = coordinator.recorder
        let paused = recorder.state == .paused
        let symbol = NSImage(systemSymbolName: paused ? "pause.circle.fill" : "stop.circle.fill", accessibilityDescription: "Stop recording")
        let configured = symbol?.withSymbolConfiguration(.init(paletteColors: [paused ? .systemOrange : .systemRed]))
        statusItem?.button?.image = configured
        statusItem?.button?.imagePosition = .imageLeading
        statusItem?.button?.title = " " + SelectionMath.formatDuration(recorder.elapsed)
        statusItem?.button?.toolTip = "Click to stop · right-click for more"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recorder = coordinator.recorder
        if recorder.state == .recording || recorder.state == .paused {
            buildRecordingMenu(menu, paused: recorder.state == .paused)
            return
        }
        // Shortcuts freed up in System Settings start working without a trip to Škljoc Settings.
        if coordinator.hasShortcutConflicts { coordinator.registerShortcuts() }

        menu.addItem(shortcutItem("Capture Area", action: .captureArea))
        menu.addItem(shortcutItem("Capture Fullscreen", action: .captureFullscreen))
        menu.addItem(shortcutItem("Capture Text", action: .captureText))
        menu.addItem(shortcutItem("Capture & Pin", action: .captureAndPin))
        menu.addItem(shortcutItem("Scrolling Capture", action: .scrollingCapture))
        menu.addItem(.separator())
        menu.addItem(shortcutItem("Record Screen", action: .recordScreen))
        let gif = menuItem("Record GIF", action: #selector(recordGIF))
        menu.addItem(gif)
        menu.addItem(.separator())

        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        recentMenu.addItem(NSMenuItem(title: "Loading…", action: nil, keyEquivalent: ""))
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        fillRecentMenu(recentMenu)
        menu.addItem(shortcutItem("Library…", action: .library))
        menu.addItem(shortcutItem("Upload Files…", action: .uploadFiles))
        menu.addItem(shortcutItem("Shorten Link in Clipboard", action: .shortenLink))
        menu.addItem(shortcutItem("Shorten Link…", action: .shortenLinkNamed))
        menu.addItem(menuItem("Open Save Folder", action: #selector(openSaveFolder)))
        menu.addItem(.separator())

        let settings = menuItem("Settings…", action: #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        if !LaunchAtLogin.isManagedByHomebrew {
            let login = menuItem("Launch at Login", action: #selector(toggleLaunchAtLogin))
            login.state = LaunchAtLogin.isEnabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Škljoc", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func buildRecordingMenu(_ menu: NSMenu, paused: Bool) {
        let stop = menuItem("Stop Recording", action: #selector(stopRecording))
        applyShortcut(coordinator.preferences.shortcut(for: .recordScreen), to: stop)
        menu.addItem(stop)
        menu.addItem(menuItem(paused ? "Resume" : "Pause", action: #selector(togglePause)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Cancel Recording", action: #selector(cancelRecording)))
    }

    private func fillRecentMenu(_ recentMenu: NSMenu) {
        Task {
            let items = await coordinator.store.recent()
            recentMenu.removeAllItems()
            if items.isEmpty {
                let empty = NSMenuItem(title: "Nothing Yet", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                recentMenu.addItem(empty)
                return
            }
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            formatter.doesRelativeDateFormatting = true
            for media in items {
                var title = formatter.string(from: media.createdAt)
                let thumbnail: NSImage
                switch media {
                case .screenshot(let capture):
                    thumbnail = capture.thumbnail()
                case .recording(let recording):
                    title += "  ·  " + recording.badge
                    thumbnail = recording.thumbnail
                }
                let item = menuItem(title, action: #selector(openRecent(_:)))
                item.representedObject = RecentBox(media)
                item.image = Self.menuThumbnail(thumbnail)
                recentMenu.addItem(item)
            }
            recentMenu.addItem(.separator())
            recentMenu.addItem(menuItem("Show All…", action: #selector(showHistory)))
        }
    }

    @objc private func showHistory() { coordinator.showLibrary(.history) }

    private func shortcutItem(_ title: String, action: ShortcutAction) -> NSMenuItem {
        let item = menuItem(title, action: #selector(performShortcutAction(_:)))
        item.representedObject = action.rawValue
        applyShortcut(coordinator.preferences.shortcut(for: action), to: item)
        return item
    }

    private func applyShortcut(_ shortcut: Shortcut?, to item: NSMenuItem) {
        guard let shortcut, let character = KeyNames.menuCharacter(for: shortcut.keyCode) else { return }
        item.keyEquivalent = character
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: shortcut.modifiers.eventFlags)
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: Menu actions

    @objc private func performShortcutAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = ShortcutAction(rawValue: raw) else { return }
        // Let the menu close first, so it isn't in the screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [coordinator] in coordinator.perform(action) }
    }

    @objc private func recordGIF() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [coordinator] in coordinator.recorder.begin(format: .gif) }
    }

    @objc private func stopRecording() { coordinator.recorder.stop() }
    @objc private func togglePause() { coordinator.recorder.togglePause() }
    @objc private func cancelRecording() { coordinator.recorder.cancel() }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? RecentBox else { return }
        coordinator.showRecent(box.item)
    }

    @objc private func openSaveFolder() {
        NSWorkspace.shared.open(coordinator.preferences.saveFolder)
    }

    @objc private func openSettings() {
        coordinator.showSettings()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
        } catch {
            let alert = NSAlert(error: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// Menu bar apps show no main menu, but text fields still get ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z from it.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Škljoc")
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    private static func menuThumbnail(_ source: NSImage) -> NSImage {
        let height: CGFloat = 32
        let width = min(64, max(24, source.size.width / max(source.size.height, 1) * height))
        return NSImage(size: CGSize(width: width, height: height), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
    }
}

/// Lets a MediaItem ride along as a menu item's represented object.
@MainActor
private final class RecentBox {
    let item: MediaItem
    init(_ item: MediaItem) { self.item = item }
}
