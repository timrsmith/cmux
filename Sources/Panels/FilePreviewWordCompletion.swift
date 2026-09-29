import Foundation

/// Buffer-word completion for the file editor: distinct identifiers
/// (letters, digits, `_`) of at least `minimumWordLength` characters that
/// start with the partial word, excluding the partial itself, sorted
/// case-insensitively.
struct FilePreviewWordCompletion {
    static let minimumWordLength = 3

    let text: String

    /// Whether `scalar` can be part of an identifier. ASCII, the bulk of any
    /// source file, is answered without a `CharacterSet` lookup.
    static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x80 {
            return value == 0x5F // _
                || (value >= 0x30 && value <= 0x39) // 0-9
                || (value >= 0x41 && value <= 0x5A) // A-Z
                || (value >= 0x61 && value <= 0x7A) // a-z
        }
        return CharacterSet.alphanumerics.contains(scalar)
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
        let prefixScalars = Array(prefix.unicodeScalars)
        let prefixIsASCII = prefixScalars.allSatisfy(\.isASCII)
        var seen: Set<String> = []
        var matches: [String] = []
        var current = String.UnicodeScalarView()
        var currentCount = 0
        var currentIsASCII = true

        // Only an identifier that survives the prefix test is materialized as
        // a `String` and deduplicated. For ASCII on both sides the scalar
        // comparison is the whole test; anything else defers to the same
        // `lowercased().hasPrefix` the results were always defined by.
        func flush() {
            defer {
                current.removeAll(keepingCapacity: true)
                currentCount = 0
                currentIsASCII = true
            }
            guard currentCount >= Self.minimumWordLength else { return }
            if prefixIsASCII, currentIsASCII {
                guard currentCount >= prefixScalars.count else { return }
                for (scalar, expected) in zip(current, prefixScalars) {
                    var value = scalar.value
                    if value >= 0x41, value <= 0x5A { value += 0x20 }
                    guard value == expected.value else { return }
                }
                let word = String(current)
                guard word != partial, seen.insert(word).inserted else { return }
                matches.append(word)
            } else {
                let word = String(current)
                guard word != partial, prefix.isEmpty || word.lowercased().hasPrefix(prefix),
                      seen.insert(word).inserted else { return }
                matches.append(word)
            }
        }
        for scalar in text.unicodeScalars {
            if Self.isIdentifierScalar(scalar) {
                current.append(scalar)
                currentCount += 1
                if !scalar.isASCII { currentIsASCII = false }
            } else if currentCount > 0 {
                flush()
            }
        }
        if currentCount > 0 {
            flush()
        }
        return matches.sorted { lhs, rhs in
            let ordering = lhs.caseInsensitiveCompare(rhs)
            return ordering == .orderedSame ? lhs < rhs : ordering == .orderedAscending
        }
    }
}
