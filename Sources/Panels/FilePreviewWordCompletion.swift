import Foundation

/// Buffer-word completion for the file editor: distinct identifiers
/// (letters, digits, `_`) of at least `minimumWordLength` characters that
/// start with the partial word, excluding the partial itself, sorted
/// case-insensitively.
struct FilePreviewWordCompletion {
    static let minimumWordLength = 3

    let text: String

    /// Whether `scalar` can be part of an identifier.
    static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }

    /// The identifier ending at `location` (UTF-16 offset) in `text`, or an
    /// empty range at `location` when no identifier precedes it.
    static func partialWordRange(in text: NSString, endingAt location: Int) -> NSRange {
        let end = max(0, min(location, text.length))
        var start = end
        while start > 0 {
            let character = text.character(at: start - 1)
            guard let scalar = Unicode.Scalar(character), isIdentifierScalar(scalar) else { break }
            start -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    func completions(forPartialWord partial: String) -> [String] {
        let prefix = partial.lowercased()
        var seen: Set<String> = []
        var matches: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            defer { current.removeAll(keepingCapacity: true) }
            guard current.count >= Self.minimumWordLength else { return }
            let word = String(current)
            guard word != partial, seen.insert(word).inserted else { return }
            guard prefix.isEmpty || word.lowercased().hasPrefix(prefix) else { return }
            matches.append(word)
        }
        for scalar in text.unicodeScalars {
            if Self.isIdentifierScalar(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                flush()
            }
        }
        if !current.isEmpty {
            flush()
        }
        return matches.sorted { lhs, rhs in
            let ordering = lhs.caseInsensitiveCompare(rhs)
            return ordering == .orderedSame ? lhs < rhs : ordering == .orderedAscending
        }
    }
}
