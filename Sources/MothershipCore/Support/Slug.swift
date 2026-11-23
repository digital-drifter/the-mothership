import Foundation

public enum Slug {
    /// Lowercases, folds diacritics, and collapses runs of non-[a-z0-9] into single hyphens.
    public static func make(_ name: String) -> String {
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
        return result.isEmpty ? "x" : result
    }
}
