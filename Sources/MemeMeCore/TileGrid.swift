import Foundation

/// The panel's tiles for keyboard focus: the user's memes (`ownRows` rows of `columns`) and, below them,
/// the GIPHY row. Slots are numbered row by row from 0; the GIPHY row starts at `giphyStart` however many
/// memes there are. Each row's tiles fill it from the left.
public struct TileGrid: Equatable, Sendable {
    public let columns: Int
    public let ownRows: Int
    public let ownCount: Int
    public let giphyCount: Int

    public init(columns: Int, ownRows: Int, ownCount: Int, giphyCount: Int) {
        self.columns = max(1, columns)
        self.ownRows = max(0, ownRows)
        self.ownCount = min(max(0, ownCount), self.columns * self.ownRows)
        self.giphyCount = min(max(0, giphyCount), self.columns)
    }

    /// The first slot of the GIPHY row.
    public var giphyStart: Int { columns * ownRows }

    /// The slot focus starts on: the first meme, else the first GIPHY tile; nil when there are none.
    public var firstSlot: Int? {
        if ownCount > 0 { return 0 }
        if giphyCount > 0 { return giphyStart }
        return nil
    }

    public func isFilled(_ slot: Int) -> Bool {
        if slot >= 0 && slot < ownCount { return true }
        return slot >= giphyStart && slot < giphyStart + giphyCount
    }

    /// The slot an arrow key moves to: along the row, or to the nearest row above or below that has tiles
    /// (keeping the column when it can). nil when there is nowhere to go.
    public func move(from slot: Int, dx: Int, dy: Int) -> Int? {
        let rowCount = ownRows + 1
        let current = min(max(0, slot), giphyStart + columns - 1)
        var row = current / columns
        var column = current % columns
        if dy != 0 {
            let step = dy > 0 ? 1 : -1
            var next = row + step
            while next >= 0 && next < rowCount && tiles(inRow: next) == 0 {
                next += step
            }
            guard next >= 0 && next < rowCount else { return nil }
            row = next
            column = min(column, tiles(inRow: row) - 1)
        }
        if dx != 0 {
            let count = tiles(inRow: row)
            guard count > 0 else { return nil }
            column = min(max(column + dx, 0), count - 1)
        }
        let target = row * columns + column
        return target != slot && isFilled(target) ? target : nil
    }

    private func tiles(inRow row: Int) -> Int {
        if row == ownRows { return giphyCount }
        return min(max(ownCount - row * columns, 0), columns)
    }
}
