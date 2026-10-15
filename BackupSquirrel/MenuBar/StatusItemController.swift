import AppKit
import Observation

/// `NSStatusItem` rather than `MenuBarExtra`, so the menu updates in place while open and the icon carries live state.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let perform: (MenuAction) -> Void
    private let statusItem: NSStatusItem
    let menu = NSMenu()
    private var renderedIconState: MenuBarIconState?

    init(model: AppModel, perform: @escaping (MenuAction) -> Void) {
        self.model = model
        self.perform = perform
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        update()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.refreshNow()
        model.refreshSystem()
    }

    private func update() {
        let (entries, iconState, tooltip) = withObservationTracking {
            let state = model.state
            return (
                StatusMenu(calendar: model.calendar).entries(for: state), currentIconState(state),
                StatusText(calendar: model.calendar).tooltip(for: state)
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.update() }
        }
        if let button = statusItem.button {
            if iconState != renderedIconState {
                button.image = MenuBarIcon.image(for: iconState)
                button.appearsDisabled = iconState == .notSetUp
                renderedIconState = iconState
            }
            if button.toolTip != tooltip {
                button.toolTip = tooltip
                button.setAccessibilityLabel("Backup-Squirrel: \(tooltip)")
            }
        }
        MenuRenderer.apply(entries, to: menu, target: self)
    }

    private func currentIconState(_ state: BackupState) -> MenuBarIconState {
        let iconState = StatusEvaluator(calendar: model.calendar).iconState(for: state)
        // Whole percent steps keep the icon from being redrawn on every progress event.
        if case .running(let fraction?) = iconState { return .running(fraction: (fraction * 100).rounded() / 100) }
        return iconState
    }

    @objc func performMenuAction(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? MenuActionBox)?.action else { return }
        perform(action)
    }
}

final class MenuActionBox: NSObject {
    let action: MenuAction

    init(_ action: MenuAction) {
        self.action = action
    }
}

@MainActor
enum MenuRenderer {
    /// Matches items by entry id and changes only what differs, so an open menu stays open and keeps its highlight.
    static func apply(_ entries: [MenuEntry], to menu: NSMenu, target: AnyObject?) {
        for (index, entry) in entries.enumerated() {
            let existing = menu.items.indices.dropFirst(index).first { menu.items[$0].identifier?.rawValue == entry.id }
            if let existing, fits(menu.items[existing], entry) {
                for _ in index..<existing { menu.removeItem(at: index) }
                configure(menu.items[index], with: entry, target: target)
            } else {
                menu.insertItem(makeItem(for: entry, target: target), at: index)
            }
        }
        while menu.items.count > entries.count { menu.removeItem(at: entries.count) }
    }

    static func makeMenu(_ entries: [MenuEntry], target: AnyObject?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        apply(entries, to: menu, target: target)
        return menu
    }

    private static func fits(_ item: NSMenuItem, _ entry: MenuEntry) -> Bool {
        guard let submenu = item.submenu else { return entry.children.isEmpty }
        return submenu.items.map { $0.identifier?.rawValue ?? "" } == entry.children.map(\.id)
    }

    private static func makeItem(for entry: MenuEntry, target: AnyObject?) -> NSMenuItem {
        let item: NSMenuItem
        switch entry.role {
        case .separator: item = .separator()
        case .header: item = .sectionHeader(title: entry.title)
        case .status, .item: item = NSMenuItem()
        }
        item.identifier = NSUserInterfaceItemIdentifier(entry.id)
        if !entry.children.isEmpty {
            item.submenu = makeMenu(entry.children, target: target)
        }
        configure(item, with: entry, target: target)
        return item
    }

    private static func configure(_ item: NSMenuItem, with entry: MenuEntry, target: AnyObject?) {
        guard entry.role != .separator else { return }
        if item.title != entry.title { item.title = entry.title }
        if item.subtitle != entry.subtitle { item.subtitle = entry.subtitle }
        guard entry.role != .header else { return }
        if item.isEnabled != entry.isEnabled { item.isEnabled = entry.isEnabled }
        if item.keyEquivalent != entry.keyEquivalent {
            item.keyEquivalent = entry.keyEquivalent
            item.keyEquivalentModifierMask = entry.keyEquivalent.isEmpty ? [] : .command
        }
        let image = entry.symbol.flatMap(image(for:))
        if item.image !== image { item.image = image }
        if (item.representedObject as? MenuActionBox)?.action != entry.action {
            item.representedObject = entry.action.map(MenuActionBox.init)
            item.target = entry.action == nil ? nil : target
            item.action = entry.action == nil ? nil : #selector(StatusItemController.performMenuAction(_:))
        }
        if let submenu = item.submenu {
            for (child, childEntry) in zip(submenu.items, entry.children) {
                configure(child, with: childEntry, target: target)
            }
        }
    }

    private static var symbolImages: [StatusSymbol: NSImage] = [:]

    /// Coloured symbols keep their colours on the selection highlight; monochrome ones follow the text colour.
    static func image(for symbol: StatusSymbol) -> NSImage? {
        if let cached = symbolImages[symbol] { return cached }
        let base = NSImage(systemSymbolName: symbol.name, accessibilityDescription: symbol.label)
        let image: NSImage? =
            switch symbol.rendering {
            case .palette:
                base?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [glyphColor(for: symbol.tint), color(for: symbol.tint)]))
            case .multicolor: base?.withSymbolConfiguration(.preferringMulticolor())
            case .monochrome: base
            }
        symbolImages[symbol] = image
        return image
    }

    static func color(for tint: StatusSymbol.Tint) -> NSColor {
        switch tint {
        case .green: .systemGreen
        case .yellow: .systemYellow
        case .red: .systemRed
        case .accent: .controlAccentColor
        case .secondary: .secondaryLabelColor
        }
    }

    /// Yellow is too light for a white glyph.
    nonisolated static func glyphColor(for tint: StatusSymbol.Tint) -> NSColor {
        tint == .yellow ? NSColor(white: 0.1, alpha: 0.85) : .white
    }
}
