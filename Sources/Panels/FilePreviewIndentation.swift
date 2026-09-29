import Foundation

/// The whitespace one indentation level uses in a file: a tab, or
/// `width` spaces.
struct FilePreviewIndentation: Equatable {
    let usesTabs: Bool
    let width: Int

    /// Lines scanned before detection falls back to spaces, so Return in a
    /// large file with no indentation never rescans the whole buffer.
    static let detectionLineLimit = 5000

    var unit: String {
        usesTabs ? "\t" : String(repeating: " ", count: width)
    }

    /// Tabs when the first indented non-blank line (within
    /// `detectionLineLimit` lines) starts with a tab; otherwise `tabWidth`
    /// spaces, the editor's `fileEditor.tabWidth` setting.
    static func detect(in text: String, tabWidth: Int) -> FilePreviewIndentation {
        let width = max(1, tabWidth)
        var atLineStart = true
        var leading: Unicode.Scalar?
        var lineCount = 0
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n", "\r", "\u{85}", "\u{2028}", "\u{2029}":
                atLineStart = true
                leading = nil
                lineCount += 1
                if lineCount >= detectionLineLimit {
                    return FilePreviewIndentation(usesTabs: false, width: width)
                }
            case " ", "\t":
                if atLineStart, leading == nil {
                    leading = scalar
                }
            default:
                if atLineStart, let leading {
                    return FilePreviewIndentation(usesTabs: leading == "\t", width: width)
                }
                atLineStart = false
                leading = nil
            }
        }
        return FilePreviewIndentation(usesTabs: false, width: width)
    }
}
