import Foundation

/// A step through a list or grid with the keyboard.
public enum GridMove: Sendable {
    case left, right, up, down, first, last
}

public enum GridNavigation {
    /// Where `move` lands, in a grid of `columns` filled row by row. Nil only when the list is empty.
    /// Going down from a row above a shorter last row lands on the last item, like Finder.
    public static func index(after move: GridMove, from index: Int?, count: Int, columns: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index, (0..<count).contains(index) else { return move == .last ? count - 1 : 0 }
        let columns = max(1, columns)
        switch move {
        case .left: return max(0, index - 1)
        case .right: return min(count - 1, index + 1)
        case .up: return index - columns >= 0 ? index - columns : index
        case .down:
            if index + columns < count { return index + columns }
            return index / columns < (count - 1) / columns ? count - 1 : index
        case .first: return 0
        case .last: return count - 1
        }
    }

    /// How many columns of at least `minimum` fit in `width`, the way an adaptive grid lays them out.
    public static func columns(width: Double, minimum: Double, spacing: Double) -> Int {
        guard width > 0, minimum > 0 else { return 1 }
        return max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
    }
}

/// The selected items of a list: one focused item that the keyboard moves, plus any others
/// added with ⇧ (a range from the anchor) or ⌘ (one at a time).
public struct ListSelection<ID: Hashable>: Equatable {
    public private(set) var focused: ID?
    public private(set) var anchor: ID?
    public private(set) var selected: Set<ID> = []

    public init(focusing id: ID? = nil) {
        focus(id)
    }

    public var count: Int { selected.count }
    public var isMultiple: Bool { selected.count > 1 }

    public func contains(_ id: ID) -> Bool { selected.contains(id) }

    /// The selected items in the order they are shown.
    public func ordered(in order: [ID]) -> [ID] {
        order.filter(selected.contains)
    }

    /// Selects only `id`, which becomes the anchor for ranges.
    public mutating func focus(_ id: ID?) {
        focused = id
        anchor = id
        selected = id.map { [$0] } ?? []
    }

    /// Selects everything between the anchor and `id`.
    public mutating func extend(to id: ID, in order: [ID]) {
        guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
            focus(id)
            return
        }
        selected = Set(order[min(from, to)...max(from, to)])
        focused = id
    }

    /// Adds or removes one item. The last selected item can't be removed.
    public mutating func toggle(_ id: ID, in order: [ID]) {
        if selected.contains(id) {
            guard selected.count > 1 else { return }
            selected.remove(id)
            if focused == id { focused = nearestSelected(to: id, in: order) }
            if anchor == id { anchor = focused }
        } else {
            selected.insert(id)
            focused = id
            anchor = id
        }
    }

    public mutating func selectAll(_ order: [ID]) {
        guard !order.isEmpty else { return }
        selected = Set(order)
        if !(focused.map(selected.contains) ?? false) { focused = order.first }
        anchor = order.first
    }

    /// Keeps only the focused item.
    public mutating func collapse() {
        focus(focused)
    }

    /// Moves the focus; with `extending`, the range from the anchor follows it.
    public mutating func move(_ move: GridMove, in order: [ID], columns: Int, extending: Bool) {
        let current = focused.flatMap { order.firstIndex(of: $0) }
        guard let index = GridNavigation.index(after: move, from: current, count: order.count, columns: columns) else {
            focus(nil)
            return
        }
        if extending, anchor != nil, current != nil {
            extend(to: order[index], in: order)
        } else {
            focus(order[index])
        }
    }

    /// Drops items that are gone, and focuses the first item when nothing is focused anymore.
    public mutating func reconcile(with order: [ID]) {
        let present = Set(order)
        selected.formIntersection(present)
        if let focused, present.contains(focused) {
            if let anchor, !present.contains(anchor) { self.anchor = focused }
            return
        }
        if let next = order.first(where: selected.contains) {
            focused = next
            anchor = next
        } else {
            focus(order.first)
        }
    }

    /// What to focus once `removed` are gone: the next item after the focused one, or the one before.
    public func nextFocus(afterRemoving removed: Set<ID>, in order: [ID]) -> ID? {
        let start = focused.flatMap { order.firstIndex(of: $0) } ?? 0
        if let after = order[min(start, order.count)...].first(where: { !removed.contains($0) }) { return after }
        return order[..<min(start, order.count)].last(where: { !removed.contains($0) })
    }

    private func nearestSelected(to id: ID, in order: [ID]) -> ID? {
        guard let index = order.firstIndex(of: id) else { return selected.first }
        let after = order[(index + 1)...].first(where: selected.contains)
        return after ?? order[..<index].last(where: selected.contains) ?? selected.first
    }
}
