import AppKit
import SkljocCore

enum LibraryTab: String, CaseIterable {
    case history = "History", uploads = "Uploads", links = "Links"
}

/// What a key does to the selected items. Each tab decides which ones it offers.
enum LibraryCommand: CaseIterable {
    case copy, edit, quickLook, pin, reveal, rename, upload, changeDestination, delete

    var key: String {
        switch self {
        case .copy: "y"
        case .edit: "e"
        case .quickLook: "space"
        case .pin: "p"
        case .reveal: "o"
        case .rename: "r"
        case .upload: "u"
        case .changeDestination: "d"
        case .delete: "⌫"
        }
    }
}

/// The parts of a tab the window and its keys work with, whatever the items are.
@MainActor
protocol LibraryPaneControl: AnyObject {
    var query: String { get set }
    var isVisualMode: Bool { get set }
    var hasMultipleSelection: Bool { get }
    func activate()
    func reload()
    func move(_ move: GridMove, extending: Bool)
    func selectAll()
    func collapseSelection()
    func commands() -> [LibraryCommand]
    var defaultCommand: LibraryCommand? { get }
    func perform(_ command: LibraryCommand)
}

/// The History, Uploads and Links tabs in one window, driven from the keyboard.
@MainActor
final class LibraryModel: ObservableObject {
    @Published var tab: LibraryTab = .history {
        didSet { if tab != oldValue { activeTabChanged() } }
    }
    @Published var isSearchFocused = false

    let history: HistoryPane
    let files: FilesPane
    let links: LinksPane
    /// Set by the window controller.
    var focusList: () -> Void = {}
    var close: () -> Void = {}

    init(history: HistoryPane, files: FilesPane, links: LinksPane) {
        self.history = history
        self.files = files
        self.links = links
    }

    var activePane: LibraryPaneControl {
        switch tab {
        case .history: history
        case .uploads: files
        case .links: links
        }
    }

    func show(_ tab: LibraryTab) {
        if self.tab == tab { activePane.activate() } else { self.tab = tab }
    }

    func focusSearch() {
        isSearchFocused = true
    }

    func leaveSearch() {
        isSearchFocused = false
        focusList()
    }

    // MARK: Keys

    /// Returns false for keys the window should handle as usual, like typing in the search field.
    func handle(_ key: KeyInput, searchFocused: Bool) -> Bool {
        if key.modifiers == .command {
            switch key.letter {
            case "1": show(.history)
            case "2": show(.uploads)
            case "3": show(.links)
            case "f": focusSearch()
            case "r": activePane.reload()
            case "a" where !searchFocused: activePane.selectAll()
            default: return false
            }
            return true
        }
        if key.code == .tab && key.modifiers.contains(.control) {
            switchTab(by: key.modifiers.contains(.shift) ? -1 : 1)
            return true
        }
        return searchFocused ? handleInSearch(key) : handleInList(key)
    }

    private func handleInSearch(_ key: KeyInput) -> Bool {
        let control = key.modifiers == .control
        switch key.code {
        case .down: activePane.move(.down, extending: false)
        case .up: activePane.move(.up, extending: false)
        case .return: performDefault()
        case .escape, .tab: leaveSearch()
        default:
            switch key.letter {
            case "j" where control, "n" where control: activePane.move(.down, extending: false)
            case "k" where control, "p" where control: activePane.move(.up, extending: false)
            default: return false
            }
        }
        return true
    }

    private func handleInList(_ key: KeyInput) -> Bool {
        guard key.modifiers.isDisjoint(with: [.command, .control, .option]) else { return false }
        let shift = key.modifiers.contains(.shift)
        let pane = activePane
        switch key.code {
        case .left: pane.move(.left, extending: shift)
        case .right: pane.move(.right, extending: shift)
        case .up: pane.move(.up, extending: shift)
        case .down: pane.move(.down, extending: shift)
        case .return: performDefault()
        case .escape: escape()
        case .delete, .forwardDelete: perform(.delete)
        case .space: perform(.quickLook)
        case .tab: focusSearch()
        case nil:
            switch key.letter {
            case "h": pane.move(.left, extending: false)
            case "l": pane.move(.right, extending: false)
            case "j", "J": pane.move(.down, extending: shift)
            case "k", "K": pane.move(.up, extending: shift)
            case "H": switchTab(by: -1)
            case "L": switchTab(by: 1)
            case "g": pane.move(.first, extending: false)
            case "G": pane.move(.last, extending: false)
            case "v", "V": toggleVisualMode()
            case "/": focusSearch()
            default:
                guard let command = LibraryCommand.allCases.first(where: { $0.key == key.letter }) else { return false }
                perform(command)
            }
        }
        return true
    }

    private func perform(_ command: LibraryCommand) {
        let pane = activePane
        guard pane.commands().contains(command) else {
            NSSound.beep()
            return
        }
        // Outside the key event, since commands may open alerts with their own event loop.
        DispatchQueue.main.async { pane.perform(command) }
    }

    private func performDefault() {
        guard let command = activePane.defaultCommand else { return NSSound.beep() }
        perform(command)
    }

    private func toggleVisualMode() {
        let pane = activePane
        if pane.isVisualMode {
            pane.isVisualMode = false
        } else {
            pane.collapseSelection()
            pane.isVisualMode = true
        }
    }

    /// Steps back: out of a multiple selection, then clears the search, then closes the window.
    private func escape() {
        let pane = activePane
        if pane.isVisualMode || pane.hasMultipleSelection {
            pane.isVisualMode = false
            pane.collapseSelection()
        } else if !pane.query.isEmpty {
            pane.query = ""
        } else {
            close()
        }
    }

    private func switchTab(by step: Int) {
        let all = LibraryTab.allCases
        let index = all.firstIndex(of: tab) ?? 0
        tab = all[(index + step + all.count) % all.count]
    }

    private func activeTabChanged() {
        if isSearchFocused { leaveSearch() }
        activePane.activate()
    }
}

/// A key press, with letters read the same on any keyboard layout.
struct KeyInput {
    enum Code {
        case left, right, up, down, `return`, escape, delete, forwardDelete, space, tab
    }

    let code: Code?
    /// The typed character, or for layouts without Latin letters, the letter at that position on a US keyboard.
    let letter: String
    let modifiers: NSEvent.ModifierFlags

    init(_ event: NSEvent) {
        modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        code = Self.codes[event.keyCode]
        let typed = event.charactersIgnoringModifiers ?? ""
        if typed.unicodeScalars.allSatisfy(\.isASCII) || Self.usLetters[event.keyCode] == nil {
            letter = typed
        } else {
            let us = Self.usLetters[event.keyCode]!
            letter = modifiers.contains(.shift) ? us.uppercased() : us
        }
    }

    private static let codes: [UInt16: Code] = [
        123: .left, 124: .right, 125: .down, 126: .up, 36: .return, 76: .return,
        53: .escape, 51: .delete, 117: .forwardDelete, 49: .space, 48: .tab,
    ]

    private static let usLetters: [UInt16: String] = [
        0: "a", 2: "d", 3: "f", 4: "h", 5: "g", 9: "v", 14: "e", 15: "r", 16: "y", 18: "1", 19: "2", 20: "3",
        31: "o", 32: "u", 35: "p", 37: "l", 38: "j", 40: "k", 44: "/", 45: "n",
    ]
}

/// Selection, search and keyboard movement shared by the tabs. Subclasses provide the items and commands.
@MainActor
class SelectableList<Item: Identifiable>: ObservableObject where Item.ID: Hashable {
    @Published var selection = ListSelection<Item.ID>()
    @Published var isVisualMode = false
    @Published var query = "" {
        didSet { if query != oldValue { queryDidChange() } }
    }
    /// Columns in a grid; lists have one.
    @Published var columns = 1

    /// The items shown, after filtering. Subclasses override this.
    var visibleItems: [Item] { [] }

    var visibleIDs: [Item.ID] { visibleItems.map(\.id) }
    var hasMultipleSelection: Bool { selection.isMultiple }

    var focusedItem: Item? {
        guard let focused = selection.focused else { return nil }
        return visibleItems.first { $0.id == focused }
    }

    /// Selected items in the order they are shown.
    var selectedItems: [Item] {
        visibleItems.filter { selection.contains($0.id) }
    }

    func move(_ move: GridMove, extending: Bool) {
        selection.move(move, in: visibleIDs, columns: columns, extending: extending || isVisualMode)
        selectionDidMove()
    }

    /// A click: ⌘ adds or removes one item, ⇧ selects a range.
    func click(_ id: Item.ID) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            selection.toggle(id, in: visibleIDs)
        } else if modifiers.contains(.shift) {
            selection.extend(to: id, in: visibleIDs)
        } else {
            isVisualMode = false
            selection.focus(id)
        }
        selectionDidMove()
    }

    func selectAll() {
        selection.selectAll(visibleIDs)
    }

    func collapseSelection() {
        selection.collapse()
    }

    func focusFirst() {
        isVisualMode = false
        selection = ListSelection(focusing: visibleIDs.first)
        selectionDidMove()
    }

    func reconcileSelection() {
        selection.reconcile(with: visibleIDs)
    }

    /// Focuses what comes after the items about to be removed, so the next one is ready.
    func focusAfterRemoving(_ ids: Set<Item.ID>) {
        isVisualMode = false
        selection.focus(selection.nextFocus(afterRemoving: ids, in: visibleIDs))
    }

    func queryDidChange() {
        focusFirst()
    }

    /// Called after the focus moved, e.g. to keep Quick Look on the focused item.
    func selectionDidMove() {}
}

extension NSAlert {
    /// Shows the first button in red and keeps Return on it. On its own, `hasDestructiveAction`
    /// makes the alert drop the default button when it lays itself out, so Return does nothing.
    func makeFirstButtonDestructive() {
        guard let button = buttons.first else { return }
        button.hasDestructiveAction = true
        layout()
        button.keyEquivalent = "\r"
    }
}

/// One-field prompts for names and addresses.
@MainActor
enum TextPrompt {
    /// Returns nil when cancelled.
    static func ask(title: String, message: String, initial: String, prefix: String? = nil) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = CGRect(x: 0, y: 0, width: 320, height: 24)
        if let prefix {
            let label = NSTextField(labelWithString: prefix)
            label.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [label, field])
            stack.spacing = 2
            stack.frame = CGRect(x: 0, y: 0, width: 360, height: 24)
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
            alert.accessoryView = stack
        } else {
            alert.accessoryView = field
        }
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}
