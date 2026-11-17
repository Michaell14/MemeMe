import Foundation

/// The panel's tiles for keyboard focus: rows of `columns` slots, top to bottom, each filled from the left with its
/// count of tiles. Slots are numbered row by row from 0, so a row's slots stay where they are however full it is.
public struct TileRows: Equatable, Sendable {
    public let columns: Int
    /// Tiles in each row, top to bottom, each clamped to `0...columns`.
    public let counts: [Int]

    public init(columns: Int, counts: [Int]) {
        let columns = max(1, columns)
        self.columns = columns
        self.counts = counts.map { min(max(0, $0), columns) }
    }

    /// Every slot of every row, filled or not.
    public var slotCount: Int { columns * counts.count }

    /// The row `slot` is in, clamped to the rows there are.
    public func row(of slot: Int) -> Int {
        guard !counts.isEmpty else { return 0 }
        return min(max(0, slot / columns), counts.count - 1)
    }

    public func isFilled(_ slot: Int) -> Bool {
        guard slot >= 0, slot < slotCount else { return false }
        return slot % columns < counts[slot / columns]
    }

    /// The first tile, top to bottom; nil when there is none.
    public var firstSlot: Int? {
        guard let row = counts.firstIndex(where: { $0 > 0 }) else { return nil }
        return row * columns
    }

    /// The last tile of `row`; nil when the row has none.
    public func lastSlot(inRow row: Int) -> Int? {
        guard row >= 0, row < counts.count, counts[row] > 0 else { return nil }
        return row * columns + counts[row] - 1
    }

    /// The slot an arrow key moves to: along the row, or to the nearest row above or below that has tiles (keeping
    /// the column when it can). nil when there is nowhere to go.
    public func move(from slot: Int, dx: Int, dy: Int) -> Int? {
        guard slotCount > 0 else { return nil }
        let current = min(max(0, slot), slotCount - 1)
        var row = current / columns
        var column = current % columns
        if dy != 0 {
            let step = dy > 0 ? 1 : -1
            var next = row + step
            while next >= 0 && next < counts.count && counts[next] == 0 {
                next += step
            }
            guard next >= 0 && next < counts.count else { return nil }
            row = next
            column = min(column, counts[row] - 1)
        }
        if dx != 0 {
            let count = counts[row]
            guard count > 0 else { return nil }
            column = min(max(column + dx, 0), count - 1)
        }
        let target = row * columns + column
        return target != slot && isFilled(target) ? target : nil
    }
}

/// Picks laid out in sections, each starting on its own row (My Stickers' row per group): which slot holds which
/// pick. A section's last row can end early, so slots and picks stop lining up; focus, the arrow keys and ⌘1–⌘9 go
/// through this map and skip the gaps.
public struct SectionedSlots: Equatable, Sendable {
    public let rows: TileRows
    /// The first row of each section (a section with no picks has no rows: its entry is the row after it).
    public let firstRows: [Int]
    /// The first pick of each section.
    public let firstPicks: [Int]
    /// The pick in each slot, row by row; nil where a row ends early.
    private let picks: [Int?]

    /// `counts`: the picks in each section, in order.
    public init(columns: Int, counts: [Int]) {
        let columns = max(1, columns)
        var rowCounts: [Int] = []
        var firstRows: [Int] = []
        var firstPicks: [Int] = []
        var picks: [Int?] = []
        var next = 0
        for count in counts {
            firstRows.append(rowCounts.count)
            firstPicks.append(next)
            var remaining = max(0, count)
            while remaining > 0 {
                let inRow = min(columns, remaining)
                rowCounts.append(inRow)
                for column in 0..<columns {
                    picks.append(column < inRow ? next + column : nil)
                }
                next += inRow
                remaining -= inRow
            }
        }
        rows = TileRows(columns: columns, counts: rowCounts)
        self.firstRows = firstRows
        self.firstPicks = firstPicks
        self.picks = picks
    }

    /// The pick in `slot`; nil for a gap or a slot past the end.
    public func pick(at slot: Int) -> Int? {
        guard slot >= 0, slot < picks.count else { return nil }
        return picks[slot]
    }

    /// The slot holding pick `index`; nil when there is no such pick.
    public func slot(ofPick index: Int) -> Int? {
        guard index >= 0 else { return nil }
        return picks.firstIndex { $0 == index }
    }

    /// The section whose rows include `row`; nil when there is none.
    public func section(ofRow row: Int) -> Int? {
        guard row >= 0, row < rows.counts.count else { return nil }
        var found: Int?
        for (section, first) in firstRows.enumerated() where first <= row {
            let end = section + 1 < firstRows.count ? firstRows[section + 1] : rows.counts.count
            if row < end { found = section }
        }
        return found
    }
}
