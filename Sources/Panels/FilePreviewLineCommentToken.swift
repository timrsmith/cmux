import Foundation

/// The line-comment leader for a file, from the highlighter's resolved
/// language name with a file-name fallback for files the extension table
/// cannot name (`Makefile`, `Dockerfile`, `.toml`, `.gitignore`, `.env`).
/// `token` is `nil` when the language is unknown or has no line comments,
/// and toggling is a no-op.
struct FilePreviewLineCommentToken: Equatable {
    let token: String?

    init(language: String?, fileName: String = "") {
        let name = fileName.lowercased()
        let ext = (name as NSString).pathExtension
        if ext == "toml" || name == "makefile" || name.hasPrefix("makefile.") || name == "dockerfile"
            || name.hasPrefix("dockerfile.") || name == ".gitignore" || name == ".env" || name.hasPrefix(".env.") {
            token = "#"
            return
        }
        guard let language = language?.lowercased() else {
            token = nil
            return
        }
        token = Self.tokensByLanguage[language]
    }

    /// Comment leaders keyed by the highlight.js language ids
    /// `LanguageCatalog` can emit. Ids the catalog never produces have no
    /// entry; file-name fallbacks are handled above, not here.
    static let tokensByLanguage: [String: String] = {
        var table: [String: String] = [:]
        let groups: [(String, [String])] = [
            ("#", ["bash", "python", "ruby", "yaml", "elixir"]),
            ("//", ["c", "cpp", "csharp", "objectivec", "javascript", "typescript", "swift", "rust", "go", "kotlin", "java"]),
            ("--", ["sql"]),
            (";", ["ini"]),
            ("%", ["erlang"]),
        ]
        for (token, languages) in groups {
            for language in languages {
                table[language] = token
            }
        }
        return table
    }()
}
