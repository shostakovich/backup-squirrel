import AppKit
import Testing

@testable import BackupSquirrel

@MainActor
struct MenuBarIconTests {
    private let states: [MenuBarIconState] = [
        .idle, .running(fraction: 0.43), .running(fraction: nil), .warning, .error, .notSetUp,
    ]
    private let scale: CGFloat = 8

    private func bitmap(_ state: MenuBarIconState, symbol: NSImage? = nil) -> NSBitmapImageRep? {
        MenuBarIcon.render(state, symbol: symbol, scale: scale).map(NSBitmapImageRep.init(cgImage:))
    }

    /// The size AppKit gives the symbols when the screen is 1x.
    private func symbolForA1xScreen(_ state: MenuBarIconState) throws -> NSImage {
        let symbol = try #require(MenuBarIcon.symbol(for: state).copy() as? NSImage)
        symbol.size = NSSize(width: 19, height: 17)
        return symbol
    }

    private func pixels(_ image: NSImage, scale: CGFloat) -> Data? {
        MenuBarIcon.render(image, scale: scale)?.dataProvider?.data as Data?
    }

    /// Alpha at a point of the badge circle; degrees run clockwise from 12 o'clock, radius in points.
    private func alpha(in bitmap: NSBitmapImageRep, degrees: CGFloat, radius: CGFloat) -> CGFloat {
        let badge = MenuBarIcon.badgeRect
        let angle = degrees * .pi / 180
        let x = (badge.midX + radius * sin(angle)) * scale
        let y = (badge.midY - radius * cos(angle)) * scale
        return bitmap.colorAt(x: Int(x), y: Int(y))?.alphaComponent ?? -1
    }

    @Test func everyStateIsATemplateOfTheSameSizeAndPlacement() {
        for state in states {
            let image = MenuBarIcon.image(for: state)
            #expect(image.isTemplate)
            #expect(image.size == MenuBarIcon.pointSize, "\(state)")
            #expect(image.alignmentRect == MenuBarIcon.alignmentRect, "\(state)")
            #expect(image.accessibilityDescription == MenuBarIcon.accessibilityDescription(for: state))
        }
        #expect(MenuBarIcon.accessibilityDescription(for: .notSetUp) == "Backup-Squirrel – nicht eingerichtet")
    }

    @Test func stillStatesAreVectorSymbolsFromTheAssetCatalog() {
        for state in [MenuBarIconState.idle, .warning, .error, .notSetUp] {
            #expect(NSImage(symbolName: MenuBarIcon.symbolName(for: state), variableValue: 1) != nil, "\(state)")
            #expect(!MenuBarIcon.image(for: state).representations.contains { $0 is NSBitmapImageRep }, "\(state)")
        }
    }

    @Test func aSymbolSizedForA1xScreenChangesNeitherSizeNorPixels() throws {
        for state in states {
            let image = MenuBarIcon.image(for: state, symbol: try symbolForA1xScreen(state))
            #expect(image.size == MenuBarIcon.pointSize, "\(state)")
            #expect(image.alignmentRect == MenuBarIcon.alignmentRect, "\(state)")
            for scale in [1.0, 2.0] {
                let expected = try #require(MenuBarIcon.render(state, scale: scale)?.dataProvider?.data as Data?)
                #expect(pixels(image, scale: scale) == expected, "\(state) at \(scale)x")
            }
        }
    }

    @Test func theRunningIconHasBothResolutions() {
        let image = MenuBarIcon.image(for: .running(fraction: 0.5))
        #expect(image.representations.map(\.pixelsWide).sorted() == [18, 36])
        #expect(MenuBarIcon.render(.idle, scale: scale)?.height == 136)
    }

    @Test(arguments: [false, true])
    func theRingSitsInTheCutOutWithAGap(onA1xScreen: Bool) throws {
        let state = MenuBarIconState.running(fraction: 1)
        let symbol = onA1xScreen ? try symbolForA1xScreen(state) : nil
        let full = try #require(bitmap(state, symbol: symbol))
        for degrees in stride(from: 0.0, to: 360, by: 30) {
            #expect(alpha(in: full, degrees: degrees, radius: 3) == 1, "progress at \(degrees)°")
        }
        for degrees in [0.0, 225, 270, 315] {
            #expect(alpha(in: full, degrees: degrees, radius: 4.5) == 0, "gap at \(degrees)°")
        }
    }

    @Test func progressIsSolidBlackWithAMinimumArc() throws {
        let barelyStarted = try #require(bitmap(.running(fraction: 0.01)))
        #expect(alpha(in: barelyStarted, degrees: 18, radius: 2.6) == 1)
        #expect(alpha(in: barelyStarted, degrees: 60, radius: 2.6) == 0)
        #expect(alpha(in: barelyStarted, degrees: 180, radius: 3.6) == 1)
        #expect(alpha(in: barelyStarted, degrees: 180, radius: 2.6) == 0)
    }
}
