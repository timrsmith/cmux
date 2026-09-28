import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Ghost rows stand for files git reports as deleted: struck through in the
/// deleted palette color with a faded icon, and fully reset when the cell is
/// reused for an ordinary node.
@MainActor
@Suite(.serialized)
struct FileExplorerGhostNodeCellTests {
    @Test
    func ghostNodeIsStruckThroughWithFadedIcon() throws {
        let cell = FileExplorerCellView(identifier: NSUserInterfaceItemIdentifier("ghost-cell-test"))
        let ghost = FileExplorerNode(name: "gone.txt", path: "/repo/gone.txt", isDirectory: false, isGhost: true)

        cell.configure(with: ghost, gitStatus: .deleted)

        let nameLabel = try #require(Self.nameLabel(in: cell))
        let iconView = try #require(Self.iconView(in: cell))
        let attributes = nameLabel.attributedStringValue.attributes(at: 0, effectiveRange: nil)
        #expect((attributes[.strikethroughStyle] as? Int) == NSUnderlineStyle.single.rawValue)
        #expect(nameLabel.attributedStringValue.string == "gone.txt")
        let deletedColor = FileExplorerStyle.current.gitColor(for: .deleted)
        #expect(nameLabel.textColor?.isEqual(deletedColor) == true)
        #expect(iconView.alphaValue == FileExplorerCellView.ghostIconAlpha)
        #expect(iconView.alphaValue < 1)
    }

    @Test
    func reusedCellResetsGhostStylingForOrdinaryNode() throws {
        let cell = FileExplorerCellView(identifier: NSUserInterfaceItemIdentifier("ghost-cell-reuse-test"))
        let ghost = FileExplorerNode(name: "gone.txt", path: "/repo/gone.txt", isDirectory: false, isGhost: true)
        cell.configure(with: ghost, gitStatus: .deleted)

        let plain = FileExplorerNode(name: "kept.swift", path: "/repo/kept.swift", isDirectory: false)
        cell.configure(with: plain)

        let nameLabel = try #require(Self.nameLabel(in: cell))
        let iconView = try #require(Self.iconView(in: cell))
        #expect(nameLabel.stringValue == "kept.swift")
        #expect(nameLabel.attributedStringValue.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) == nil)
        #expect(nameLabel.textColor?.isEqual(NSColor.labelColor) == true)
        #expect(iconView.alphaValue == 1)
    }

    @Test
    func ghostNodesAreNeitherExpandableNorSortedAheadOfDirectories() {
        let directory = FileExplorerNode(name: "src", path: "/repo/src", isDirectory: true)
        let ghost = FileExplorerNode(name: "Alpha.txt", path: "/repo/Alpha.txt", isDirectory: false, isGhost: true)
        let file = FileExplorerNode(name: "beta.txt", path: "/repo/beta.txt", isDirectory: false)

        #expect(!ghost.isExpandable)
        #expect(FileExplorerNode.sorted([file, ghost, directory]).map(\.name) == ["src", "Alpha.txt", "beta.txt"])
    }

    private static func nameLabel(in cell: FileExplorerCellView) -> NSTextField? {
        cell.subviews.compactMap { $0 as? NSTextField }.first
    }

    private static func iconView(in cell: FileExplorerCellView) -> NSView? {
        cell.subviews.first { !($0 is NSTextField) && !($0 is NSProgressIndicator) }
    }
}
