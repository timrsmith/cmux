import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure-mapping coverage for the file explorer's per-type icons: filename and
/// extension lookup, case folding, fallbacks, and that every symbol the
/// catalog names exists on the deployment target so no row falls back to the
/// blank render.
@Suite struct FileExplorerFileTypeIconTests {
    @Test func extensionsMapToLanguageIcons() {
        let expectations: [(String, String, FileTypeIconColor)] = [
            ("App.swift", "swift", .orange),
            ("index.js", "j.square.fill", .yellow),
            ("index.mjs", "j.square.fill", .yellow),
            ("component.jsx", "j.square.fill", .yellow),
            ("main.ts", "t.square.fill", .blue),
            ("view.tsx", "t.square.fill", .blue),
            ("types.d.ts", "t.square.fill", .blue),
            ("script.py", "p.square.fill", .blue),
            ("server.rb", "diamond.fill", .red),
            ("lib.rs", "r.square.fill", .orange),
            ("main.go", "g.square.fill", .cyan),
            ("Main.java", "cup.and.saucer.fill", .orange),
            ("styles.css", "paintbrush.fill", .blue),
            ("index.html", "chevron.left.forwardslash.chevron.right", .orange),
            ("config.json", "curlybraces", .yellow),
            ("ci.yml", "list.bullet.indent", .purple),
            ("Cargo.toml", "cube.box.fill", .orange),
            ("README.md", "m.square.fill", .blue),
            ("notes.txt", "doc.text.fill", .gray),
            ("run.sh", "terminal.fill", .green),
            ("query.sql", "cylinder.fill", .teal),
            ("photo.png", "photo.fill", .purple),
            ("clip.mp4", "film.fill", .pink),
            ("song.mp3", "waveform", .pink),
            ("paper.pdf", "doc.richtext.fill", .red),
            ("bundle.zip", "archivebox.fill", .gray),
            ("Inter.woff2", "textformat", .gray),
            ("data.csv", "tablecells.fill", .green),
            ("Info.plist", "list.bullet.rectangle.fill", .gray),
            ("Localizable.xcstrings", "globe", .blue),
        ]
        for (name, symbol, color) in expectations {
            let icon = FileTypeIcon.icon(forFileName: name)
            #expect(icon.symbol == symbol, "\(name) symbol was \(icon.symbol)")
            #expect(icon.color == color, "\(name) color was \(icon.color)")
        }
    }

    @Test func exactFileNamesWinOverExtensions() {
        #expect(FileTypeIcon.icon(forFileName: "package.json").symbol == "cube.box.fill")
        #expect(FileTypeIcon.icon(forFileName: "package-lock.json").symbol == "lock.fill")
        #expect(FileTypeIcon.icon(forFileName: "yarn.lock").symbol == "lock.fill")
        #expect(FileTypeIcon.icon(forFileName: "pnpm-lock.yaml").symbol == "lock.fill")
        #expect(FileTypeIcon.icon(forFileName: "Package.resolved").symbol == "lock.fill")
        #expect(FileTypeIcon.icon(forFileName: "Dockerfile").symbol == "shippingbox.fill")
        #expect(FileTypeIcon.icon(forFileName: "docker-compose.yml").symbol == "shippingbox.fill")
        #expect(FileTypeIcon.icon(forFileName: "Makefile").symbol == "hammer.fill")
        #expect(FileTypeIcon.icon(forFileName: ".gitignore").symbol == "arrow.triangle.branch")
        #expect(FileTypeIcon.icon(forFileName: ".env").symbol == "key.fill")
        #expect(FileTypeIcon.icon(forFileName: ".nvmrc").symbol == "gearshape.fill")
        #expect(FileTypeIcon.icon(forFileName: "Package.swift").symbol == "swift")
    }

    @Test func prefixesCoverReadmeLicenseAndEnvVariants() {
        #expect(FileTypeIcon.icon(forFileName: "README").symbol == "m.square.fill")
        #expect(FileTypeIcon.icon(forFileName: "readme.rst").symbol == "m.square.fill")
        #expect(FileTypeIcon.icon(forFileName: "LICENSE").symbol == "checkmark.seal.fill")
        #expect(FileTypeIcon.icon(forFileName: "LICENSE-MIT.txt").symbol == "checkmark.seal.fill")
        #expect(FileTypeIcon.icon(forFileName: "Dockerfile.dev").symbol == "shippingbox.fill")
        #expect(FileTypeIcon.icon(forFileName: ".env.staging").symbol == "key.fill")
        #expect(FileTypeIcon.icon(forFileName: "tsconfig.build.json").symbol == "curlybraces")
    }

    @Test func lookupIsCaseInsensitive() {
        #expect(FileTypeIcon.icon(forFileName: "MAIN.TS") == FileTypeIcon.icon(forFileName: "main.ts"))
        #expect(FileTypeIcon.icon(forFileName: "DOCKERFILE") == FileTypeIcon.icon(forFileName: "dockerfile"))
        #expect(FileTypeIcon.icon(forFileName: "Photo.PNG") == FileTypeIcon.icon(forFileName: "photo.png"))
    }

    @Test func unknownNamesFallBackToDocumentOrDotfile() {
        #expect(FileTypeIcon.icon(forFileName: "lpoptions") == .genericFile)
        #expect(FileTypeIcon.icon(forFileName: "archive.unknownext") == .genericFile)
        #expect(FileTypeIcon.icon(forFileName: ".somerc") == .genericDotfile)
        #expect(FileTypeIcon.icon(forFileName: "") == .genericFile)
        #expect(FileTypeIcon.genericFile.symbol == "doc")
    }

    @Test func everyCatalogSymbolExistsOnThisSystem() {
        for symbol in FileTypeIcon.allSymbols.sorted() {
            #expect(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                "SF Symbol \(symbol) is missing; the row would render blank"
            )
        }
    }

    @Test func monochromeStylesCollapseEveryColorOntoTheNeutralTint() {
        for color in FileTypeIconColor.allCases {
            #expect(FileExplorerStyle.terminalStealth.fileTypeTint(color) === FileExplorerStyle.terminalStealth.fileIconTint)
            #expect(FileExplorerStyle.finder.fileTypeTint(color) === FileExplorerStyle.finder.fileIconTint)
        }
        #expect(FileExplorerStyle.highDensity.fileTypeTint(.blue) !== FileExplorerStyle.highDensity.fileIconTint)
        #expect(FileExplorerStyle.highDensity.fileTypeTint(.gray) === FileExplorerStyle.highDensity.fileIconTint)
    }
}
