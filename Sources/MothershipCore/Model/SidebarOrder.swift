import Foundation

/// The order of rows inside one sidebar group.
public enum SidebarOrder {
    /// The ids after a drag: the rows at `source` are taken out and put back before the row that was at
    /// `destination` (the same result as SwiftUI's `move(fromOffsets:toOffset:)`). Offsets outside the
    /// list leave it unchanged.
    public static func moving(_ ids: [String], from source: IndexSet, to destination: Int) -> [String] {
        guard (0...ids.count).contains(destination), source.allSatisfy({ ids.indices.contains($0) }) else { return ids }
        let moved = source.map { ids[$0] }
        var rest = ids.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertion = destination - source.count(in: 0..<destination)
        rest.insert(contentsOf: moved, at: insertion)
        return rest
    }

    /// `ids` named in `saved` come first, in the saved order; the rest follow in the order given.
    /// Saved names that are not in `ids` are skipped.
    public static func applying(_ saved: [String], to ids: [String]) -> [String] {
        let present = Set(ids)
        var seen = Set<String>()
        let first = saved.filter { present.contains($0) && seen.insert($0).inserted }
        return first + ids.filter { !seen.contains($0) }
    }
}
