import Foundation

public enum Slug {
    /// Lowercases, folds diacritics, and collapses runs of non-[a-z0-9] into single hyphens.
    /// Returns `fallback` when nothing is left.
    public static func make(_ name: String, fallback: String = "x") -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var result = ""
        var pendingHyphen = false
        for scalar in folded.unicodeScalars {
            let isAllowed = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
            if isAllowed {
                if pendingHyphen && !result.isEmpty { result.append("-") }
                pendingHyphen = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        return result.isEmpty ? fallback : result
    }

    /// The slug of `name`, with `-2`, `-3`, … appended until it is not in `taken`.
    public static func unique(_ name: String, fallback: String, taken: Set<String>) -> String {
        let base = make(name, fallback: fallback)
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base)-\(number)") { number += 1 }
        return "\(base)-\(number)"
    }
}
