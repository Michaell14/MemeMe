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
