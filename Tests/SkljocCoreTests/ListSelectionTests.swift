import Foundation
import Testing
@testable import SkljocCore

@Suite struct GridNavigationTests {
    // 0 1 2
    // 3 4 5
    // 6 7
    private func move(_ move: GridMove, from index: Int?) -> Int? {
        GridNavigation.index(after: move, from: index, count: 8, columns: 3)
    }

    @Test func movesWithinTheGrid() {
        #expect(move(.right, from: 1) == 2)
        #expect(move(.left, from: 1) == 0)
        #expect(move(.down, from: 1) == 4)
        #expect(move(.up, from: 4) == 1)
    }

    @Test func stopsAtTheEdges() {
        #expect(move(.left, from: 0) == 0)
        #expect(move(.right, from: 7) == 7)
        #expect(move(.up, from: 2) == 2)
        #expect(move(.down, from: 7) == 7)
    }

    @Test func downOverAShorterLastRowLandsOnTheLastItem() {
        #expect(move(.down, from: 5) == 7)
        #expect(move(.down, from: 4) == 7)
    }

    @Test func firstAndLast() {
        #expect(move(.first, from: 5) == 0)
        #expect(move(.last, from: 1) == 7)
    }

    @Test func startsAtTheTopWithoutAFocus() {
        #expect(move(.down, from: nil) == 0)
        #expect(move(.last, from: nil) == 7)
        #expect(move(.down, from: 42) == 0)
    }

    @Test func emptyListHasNothingToFocus() {
        #expect(GridNavigation.index(after: .down, from: 0, count: 0, columns: 3) == nil)
    }

    @Test func listsAreOneColumn() {
        #expect(GridNavigation.index(after: .down, from: 0, count: 3, columns: 1) == 1)
        #expect(GridNavigation.index(after: .down, from: 2, count: 3, columns: 0) == 2)
    }

    @Test func countsColumnsLikeAnAdaptiveGrid() {
        #expect(GridNavigation.columns(width: 190, minimum: 190, spacing: 14) == 1)
        #expect(GridNavigation.columns(width: 393, minimum: 190, spacing: 14) == 1)
        #expect(GridNavigation.columns(width: 394, minimum: 190, spacing: 14) == 2)
        #expect(GridNavigation.columns(width: 0, minimum: 190, spacing: 14) == 1)
    }
}

@Suite struct ListSelectionTests {
    private let order = ["a", "b", "c", "d", "e"]

    @Test func focusSelectsOnlyThatItem() {
        var selection = ListSelection(focusing: "b")
        selection.focus("c")
        #expect(selection.focused == "c")
        #expect(selection.selected == ["c"])
    }

    @Test func movingWithoutExtendingKeepsOneItem() {
        var selection = ListSelection(focusing: "b")
        selection.move(.down, in: order, columns: 1, extending: false)
        #expect(selection.focused == "c")
        #expect(selection.selected == ["c"])
    }

    @Test func extendingSelectsTheRangeFromTheAnchor() {
        var selection = ListSelection(focusing: "b")
        selection.move(.down, in: order, columns: 1, extending: true)
        selection.move(.down, in: order, columns: 1, extending: true)
        #expect(selection.selected == ["b", "c", "d"])
        selection.move(.up, in: order, columns: 1, extending: true)
        selection.move(.up, in: order, columns: 1, extending: true)
        selection.move(.up, in: order, columns: 1, extending: true)
        #expect(selection.selected == ["a", "b"])
        #expect(selection.focused == "a")
        #expect(selection.anchor == "b")
    }

    @Test func toggleAddsAndRemoves() {
        var selection = ListSelection(focusing: "a")
        selection.toggle("c", in: order)
        #expect(selection.selected == ["a", "c"])
        #expect(selection.focused == "c")
        selection.toggle("c", in: order)
        #expect(selection.selected == ["a"])
        #expect(selection.focused == "a")
        selection.toggle("a", in: order)
        #expect(selection.selected == ["a"])
    }

    @Test func selectAllAndCollapse() {
        var selection = ListSelection(focusing: "c")
        selection.selectAll(order)
        #expect(selection.count == 5)
        #expect(selection.focused == "c")
        selection.collapse()
        #expect(selection.selected == ["c"])
    }

    @Test func orderedFollowsTheList() {
        var selection = ListSelection(focusing: "d")
        selection.toggle("a", in: order)
        #expect(selection.ordered(in: order) == ["a", "d"])
    }

    @Test func reconcileDropsMissingItemsAndRefocuses() {
        var selection = ListSelection(focusing: "b")
        selection.extend(to: "d", in: order)
        selection.reconcile(with: ["a", "b", "c"])
        #expect(selection.selected == ["b", "c"])
        #expect(selection.focused == "b")

        selection.reconcile(with: ["x", "y"])
        #expect(selection.focused == "x")
        #expect(selection.selected == ["x"])

        selection.reconcile(with: [])
        #expect(selection.focused == nil)
        #expect(selection.selected.isEmpty)
    }

    @Test func nextFocusAfterRemovingIsTheFollowingItem() {
        var selection = ListSelection(focusing: "b")
        selection.extend(to: "c", in: order)
        #expect(selection.nextFocus(afterRemoving: ["b", "c"], in: order) == "d")
    }

    @Test func nextFocusFallsBackToThePreviousItem() {
        let selection = ListSelection(focusing: "e")
        #expect(selection.nextFocus(afterRemoving: ["e"], in: order) == "d")
        #expect(selection.nextFocus(afterRemoving: Set(order), in: order) == nil)
    }
}

@Suite struct CaptureTitleTests {
    @Test func usesTheTitleAsTheFileName() {
        let date = Date(timeIntervalSince1970: 1_794_492_202)
        #expect(CaptureFileName.make(title: "Login bug", date: date, fileExtension: "png") == "Login bug.png")
        #expect(CaptureFileName.make(title: "  ", date: date, fileExtension: "png", timeZone: TimeZone(identifier: "UTC")!)
            == "Skljoc 2026-11-12 at 14.03.22.png")
        #expect(CaptureFileName.make(title: nil, date: date, fileExtension: "mp4", timeZone: TimeZone(identifier: "UTC")!)
            == "Skljoc 2026-11-12 at 14.03.22.mp4")
    }

    @Test func makesTitlesSafeForFileNames() {
        #expect(CaptureFileName.safeName("a/b:c") == "a-b-c")
        #expect(CaptureFileName.safeName("..hidden") == "hidden")
        #expect(CaptureFileName.safeName("two\nlines") == "two lines")
        #expect(CaptureFileName.safeName(String(repeating: "x", count: 300))?.count == 200)
        #expect(CaptureFileName.safeName("...") == nil)
    }

    @Test func storesTitlesNextToTheCapture() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("skljoc-title-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = folder.appendingPathComponent("1794489938929.png")

        #expect(MediaFiles.title(for: capture) == nil)
        try MediaFiles.setTitle("  Offer v2 ", for: capture)
        #expect(MediaFiles.title(for: capture) == "Offer v2")
        #expect(MediaFiles.baseName(of: MediaFiles.titleURL(for: capture)) == "1794489938929")
        try MediaFiles.setTitle("", for: capture)
        #expect(MediaFiles.title(for: capture) == nil)
        #expect(!FileManager.default.fileExists(atPath: MediaFiles.titleURL(for: capture).path))
    }
}
