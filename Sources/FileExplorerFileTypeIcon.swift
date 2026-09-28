import Foundation

/// Color category for a file type icon. Palettes map each category to an
/// appearance-aware tint (or to their neutral icon color when the style is
/// monochrome), so the catalog itself stays free of AppKit.
enum FileTypeIconColor: CaseIterable, Equatable, Sendable {
    case blue, yellow, orange, green, teal, purple, pink, red, cyan, gray
}

/// An SF Symbol plus color category for one file in the explorer tree.
struct FileTypeIcon: Equatable, Sendable {
    let symbol: String
    let color: FileTypeIconColor

    /// The generic document icon used when nothing in the catalog matches.
    static let genericFile = FileTypeIcon(symbol: "doc", color: .gray)
    /// Unknown dotfiles read as configuration rather than documents, so they
    /// share the catalog's configuration icon.
    static let genericDotfile = config

    /// Resolves the icon for a file name. Lookup order: exact lowercased file
    /// name, then well-known name prefixes (README, LICENSE, Dockerfile.*),
    /// then the extension (with `.d.ts`-style compound suffixes folded onto the
    /// final extension), then the dotfile or generic fallback. Directories are
    /// not handled here; the cell draws folders itself.
    static func icon(forFileName rawName: String) -> FileTypeIcon {
        let name = rawName.lowercased()
        if let exact = byFileName[name] {
            return exact
        }
        for (prefix, icon) in byFileNamePrefix where name.hasPrefix(prefix) {
            return icon
        }
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let byExt = byExtension[ext] {
            return byExt
        }
        if name.hasPrefix(".") {
            return genericDotfile
        }
        return genericFile
    }

    /// Every symbol the catalog can return, for tests that check the symbols
    /// exist on the deployment target.
    static var allSymbols: Set<String> {
        var symbols = Set(byFileName.values.map(\.symbol))
        symbols.formUnion(byFileNamePrefix.map(\.icon.symbol))
        symbols.formUnion(byExtension.values.map(\.symbol))
        symbols.insert(genericFile.symbol)
        symbols.insert(genericDotfile.symbol)
        return symbols
    }

    // MARK: - Catalog

    private static let script = FileTypeIcon(symbol: "terminal.fill", color: .green)
    private static let javascript = FileTypeIcon(symbol: "j.square.fill", color: .yellow)
    private static let typescript = FileTypeIcon(symbol: "t.square.fill", color: .blue)
    private static let json = FileTypeIcon(symbol: "curlybraces", color: .yellow)
    private static let markdown = FileTypeIcon(symbol: "m.square.fill", color: .blue)
    private static let markup = FileTypeIcon(symbol: "chevron.left.forwardslash.chevron.right", color: .orange)
    private static let xml = FileTypeIcon(symbol: "chevron.left.forwardslash.chevron.right", color: .gray)
    private static let stylesheet = FileTypeIcon(symbol: "paintbrush.fill", color: .blue)
    private static let data = FileTypeIcon(symbol: "list.bullet.indent", color: .purple)
    private static let config = FileTypeIcon(symbol: "gearshape.fill", color: .gray)
    private static let plainText = FileTypeIcon(symbol: "doc.text.fill", color: .gray)
    private static let image = FileTypeIcon(symbol: "photo.fill", color: .purple)
    private static let video = FileTypeIcon(symbol: "film.fill", color: .pink)
    private static let audio = FileTypeIcon(symbol: "waveform", color: .pink)
    private static let archive = FileTypeIcon(symbol: "archivebox.fill", color: .gray)
    private static let font = FileTypeIcon(symbol: "textformat", color: .gray)
    private static let lockfile = FileTypeIcon(symbol: "lock.fill", color: .gray)
    private static let git = FileTypeIcon(symbol: "arrow.triangle.branch", color: .orange)
    private static let docker = FileTypeIcon(symbol: "shippingbox.fill", color: .cyan)
    private static let secrets = FileTypeIcon(symbol: "key.fill", color: .yellow)
    private static let table = FileTypeIcon(symbol: "tablecells.fill", color: .green)
    private static let swift = FileTypeIcon(symbol: "swift", color: .orange)

    private static let byFileName: [String: FileTypeIcon] = [
        // Package manifests
        "package.json": FileTypeIcon(symbol: "cube.box.fill", color: .red),
        "cargo.toml": FileTypeIcon(symbol: "cube.box.fill", color: .orange),
        "pyproject.toml": FileTypeIcon(symbol: "cube.box.fill", color: .blue),
        "requirements.txt": FileTypeIcon(symbol: "cube.box.fill", color: .blue),
        "go.mod": FileTypeIcon(symbol: "cube.box.fill", color: .cyan),
        "go.sum": lockfile,
        "gemfile": FileTypeIcon(symbol: "cube.box.fill", color: .red),
        "podfile": FileTypeIcon(symbol: "cube.box.fill", color: .red),
        "package.swift": swift,
        // Lockfiles
        "package-lock.json": lockfile,
        "yarn.lock": lockfile,
        "pnpm-lock.yaml": lockfile,
        "bun.lock": lockfile,
        "bun.lockb": lockfile,
        "cargo.lock": lockfile,
        "gemfile.lock": lockfile,
        "podfile.lock": lockfile,
        "poetry.lock": lockfile,
        "uv.lock": lockfile,
        "package.resolved": lockfile,
        "composer.lock": lockfile,
        // Build and tooling
        "makefile": FileTypeIcon(symbol: "hammer.fill", color: .orange),
        "justfile": FileTypeIcon(symbol: "hammer.fill", color: .orange),
        "rakefile": FileTypeIcon(symbol: "hammer.fill", color: .red),
        "cmakelists.txt": FileTypeIcon(symbol: "hammer.fill", color: .blue),
        "dockerfile": docker,
        ".dockerignore": docker,
        "docker-compose.yml": docker,
        "docker-compose.yaml": docker,
        "compose.yml": docker,
        "compose.yaml": docker,
        "jenkinsfile": FileTypeIcon(symbol: "gearshape.2.fill", color: .red),
        "procfile": config,
        // Git
        ".gitignore": git,
        ".gitattributes": git,
        ".gitmodules": git,
        ".gitkeep": git,
        ".mailmap": git,
        // Secrets and env
        ".env": secrets,
        ".env.local": secrets,
        ".env.example": secrets,
        ".env.sample": secrets,
        ".env.development": secrets,
        ".env.production": secrets,
        ".env.test": secrets,
        ".npmrc": config,
        ".nvmrc": config,
        ".editorconfig": config,
        ".prettierrc": config,
        ".prettierignore": config,
        ".eslintrc": config,
        ".eslintignore": config,
        ".babelrc": config,
        ".xcode-version": config,
        ".tool-versions": config,
        ".ruby-version": config,
        ".python-version": config,
        // Documents
        "codeowners": FileTypeIcon(symbol: "person.2.fill", color: .gray),
        "changelog": markdown,
        "changelog.md": markdown,
        "contributing.md": markdown,
        "claude.md": markdown,
        "agents.md": markdown,
    ]

    private static let byFileNamePrefix: [(prefix: String, icon: FileTypeIcon)] = [
        ("readme", markdown),
        ("license", FileTypeIcon(symbol: "checkmark.seal.fill", color: .gray)),
        ("licence", FileTypeIcon(symbol: "checkmark.seal.fill", color: .gray)),
        ("copying", FileTypeIcon(symbol: "checkmark.seal.fill", color: .gray)),
        ("dockerfile.", docker),
        (".env.", secrets),
        ("tsconfig", json),
        ("jsconfig", json),
    ]

    private static let byExtension: [String: FileTypeIcon] = [
        // Apple
        "swift": swift,
        "xcodeproj": FileTypeIcon(symbol: "hammer.fill", color: .blue),
        "xcworkspace": FileTypeIcon(symbol: "hammer.fill", color: .blue),
        "xcassets": FileTypeIcon(symbol: "paintpalette.fill", color: .blue),
        "entitlements": FileTypeIcon(symbol: "lock.shield.fill", color: .blue),
        "xcstrings": FileTypeIcon(symbol: "globe", color: .blue),
        "strings": FileTypeIcon(symbol: "globe", color: .blue),
        "stringsdict": FileTypeIcon(symbol: "globe", color: .blue),
        "plist": FileTypeIcon(symbol: "list.bullet.rectangle.fill", color: .gray),
        "xib": xml,
        "storyboard": xml,
        "pbxproj": FileTypeIcon(symbol: "hammer.fill", color: .blue),
        "m": FileTypeIcon(symbol: "c.square.fill", color: .blue),
        "mm": FileTypeIcon(symbol: "c.square.fill", color: .blue),
        "metal": FileTypeIcon(symbol: "cpu.fill", color: .gray),
        // JavaScript and TypeScript
        "js": javascript,
        "mjs": javascript,
        "cjs": javascript,
        "jsx": javascript,
        "ts": typescript,
        "mts": typescript,
        "cts": typescript,
        "tsx": typescript,
        "vue": FileTypeIcon(symbol: "v.square.fill", color: .green),
        "svelte": FileTypeIcon(symbol: "s.square.fill", color: .orange),
        "astro": FileTypeIcon(symbol: "a.square.fill", color: .purple),
        // Other languages
        "py": FileTypeIcon(symbol: "p.square.fill", color: .blue),
        "pyi": FileTypeIcon(symbol: "p.square.fill", color: .blue),
        "ipynb": FileTypeIcon(symbol: "book.fill", color: .orange),
        "rb": FileTypeIcon(symbol: "diamond.fill", color: .red),
        "erb": FileTypeIcon(symbol: "diamond.fill", color: .red),
        "rs": FileTypeIcon(symbol: "r.square.fill", color: .orange),
        "go": FileTypeIcon(symbol: "g.square.fill", color: .cyan),
        "java": FileTypeIcon(symbol: "cup.and.saucer.fill", color: .orange),
        "kt": FileTypeIcon(symbol: "k.square.fill", color: .purple),
        "kts": FileTypeIcon(symbol: "k.square.fill", color: .purple),
        "cs": FileTypeIcon(symbol: "c.square.fill", color: .green),
        "c": FileTypeIcon(symbol: "c.square.fill", color: .blue),
        "h": FileTypeIcon(symbol: "h.square.fill", color: .purple),
        "hpp": FileTypeIcon(symbol: "h.square.fill", color: .purple),
        "hh": FileTypeIcon(symbol: "h.square.fill", color: .purple),
        "cpp": FileTypeIcon(symbol: "c.square.fill", color: .purple),
        "cc": FileTypeIcon(symbol: "c.square.fill", color: .purple),
        "cxx": FileTypeIcon(symbol: "c.square.fill", color: .purple),
        "php": FileTypeIcon(symbol: "p.square.fill", color: .purple),
        "lua": FileTypeIcon(symbol: "l.square.fill", color: .blue),
        "dart": FileTypeIcon(symbol: "d.square.fill", color: .cyan),
        "zig": FileTypeIcon(symbol: "z.square.fill", color: .orange),
        "ex": FileTypeIcon(symbol: "e.square.fill", color: .purple),
        "exs": FileTypeIcon(symbol: "e.square.fill", color: .purple),
        "erl": FileTypeIcon(symbol: "e.square.fill", color: .red),
        "hs": FileTypeIcon(symbol: "h.square.fill", color: .purple),
        "scala": FileTypeIcon(symbol: "s.square.fill", color: .red),
        "clj": FileTypeIcon(symbol: "c.square.fill", color: .green),
        "r": FileTypeIcon(symbol: "r.square.fill", color: .blue),
        "pl": FileTypeIcon(symbol: "p.square.fill", color: .blue),
        "sql": FileTypeIcon(symbol: "cylinder.fill", color: .teal),
        "graphql": FileTypeIcon(symbol: "point.3.connected.trianglepath.dotted", color: .pink),
        "gql": FileTypeIcon(symbol: "point.3.connected.trianglepath.dotted", color: .pink),
        "proto": FileTypeIcon(symbol: "cube.fill", color: .blue),
        "wasm": FileTypeIcon(symbol: "cpu.fill", color: .purple),
        // Shell
        "sh": script,
        "bash": script,
        "zsh": script,
        "fish": script,
        "ps1": script,
        "bat": script,
        "cmd": script,
        // Web
        "html": markup,
        "htm": markup,
        "css": stylesheet,
        "scss": FileTypeIcon(symbol: "paintbrush.fill", color: .pink),
        "sass": FileTypeIcon(symbol: "paintbrush.fill", color: .pink),
        "less": FileTypeIcon(symbol: "paintbrush.fill", color: .blue),
        // Data and config
        "json": json,
        "jsonc": json,
        "json5": json,
        "yaml": data,
        "yml": data,
        "toml": config,
        "ini": config,
        "cfg": config,
        "conf": config,
        "env": secrets,
        "xml": xml,
        "csv": table,
        "tsv": table,
        "lock": lockfile,
        // Text
        "md": markdown,
        "markdown": markdown,
        "mdx": markdown,
        "rst": plainText,
        "adoc": plainText,
        "txt": plainText,
        "log": plainText,
        "pdf": FileTypeIcon(symbol: "doc.richtext.fill", color: .red),
        // Media
        "png": image,
        "jpg": image,
        "jpeg": image,
        "gif": image,
        "webp": image,
        "heic": image,
        "bmp": image,
        "tiff": image,
        "tif": image,
        "ico": image,
        "icns": image,
        "svg": FileTypeIcon(symbol: "photo.fill", color: .orange),
        "mp4": video,
        "mov": video,
        "mkv": video,
        "webm": video,
        "avi": video,
        "mp3": audio,
        "wav": audio,
        "m4a": audio,
        "aac": audio,
        "flac": audio,
        "ogg": audio,
        // Archives and fonts
        "zip": archive,
        "tar": archive,
        "gz": archive,
        "tgz": archive,
        "xz": archive,
        "bz2": archive,
        "7z": archive,
        "rar": archive,
        "dmg": archive,
        "ttf": font,
        "otf": font,
        "woff": font,
        "woff2": font,
    ]
}
