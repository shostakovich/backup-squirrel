import AppKit
import SwiftUI

struct StatusSymbolView: View {
    let symbol: StatusSymbol

    var body: some View {
        styled(Image(systemName: symbol.name))
            .accessibilityLabel(symbol.label)
            .help(symbol.label)
    }

    @ViewBuilder
    private func styled(_ image: Image) -> some View {
        switch symbol.rendering {
        case .palette:
            image.symbolRenderingMode(.palette).foregroundStyle(symbol.tint.glyphColor, symbol.tint.color)
        case .multicolor:
            image.symbolRenderingMode(.multicolor)
        case .monochrome:
            image.symbolRenderingMode(.monochrome).foregroundStyle(symbol.tint.color)
        }
    }
}

extension StatusSymbol.Tint {
    var color: Color {
        switch self {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        case .accent: .accentColor
        case .secondary: .secondary
        }
    }

    var glyphColor: Color {
        Color(nsColor: MenuRenderer.glyphColor(for: self))
    }
}

struct FileRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: Self.icon(for: url))
                .resizable()
                .frame(width: 16, height: 16)
            Text(Self.displayName(of: url))
                .lineLimit(1)
            Text(Self.abbreviatedPath(of: url))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(url.path)
    }

    private static var trash: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".Trash", isDirectory: true)
    }

    static func icon(for url: URL) -> NSImage {
        if url.standardizedFileURL == trash.standardizedFileURL, let icon = NSImage(named: NSImage.trashEmptyName) {
            return icon
        }
        return FileManager.default.fileExists(atPath: url.path)
            ? NSWorkspace.shared.icon(forFile: url.path) : NSWorkspace.shared.icon(for: .folder)
    }

    static func displayName(of url: URL) -> String {
        if url.standardizedFileURL == trash.standardizedFileURL { return "Papierkorb" }
        return FileManager.default.fileExists(atPath: url.path)
            ? FileManager.default.displayName(atPath: url.path) : url.lastPathComponent
    }

    static func abbreviatedPath(of url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// An exclusion pattern, with an icon so it lines up with folder rows.
struct PatternRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "asterisk")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            content()
        }
    }
}

extension AppModel {
    func binding(forPlan id: Plan.ID) -> Binding<Plan>? {
        guard let plan = plan(id) else { return nil }
        return Binding(
            get: { self.plan(id) ?? plan },
            set: { newValue in
                guard let index = self.plans.firstIndex(where: { $0.id == id }) else { return }
                self.plans[index] = newValue
            }
        )
    }

    func binding(forTarget id: Target.ID) -> Binding<Target>? {
        guard let target = target(id) else { return nil }
        return Binding(
            get: { self.target(id) ?? target },
            set: { newValue in
                guard let index = self.targets.firstIndex(where: { $0.id == id }) else { return }
                self.targets[index] = newValue
            }
        )
    }
}
