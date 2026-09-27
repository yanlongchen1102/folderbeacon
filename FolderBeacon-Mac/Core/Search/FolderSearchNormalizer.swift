import Foundation

nonisolated enum FolderSearchNormalizer {
    static func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func tokens(for query: String) -> [String] {
        normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    static func escapeLike(_ value: String) -> String {
        value.replacing("\\", with: "\\\\").replacing("%", with: "\\%").replacing("_", with: "\\_")
    }
}
