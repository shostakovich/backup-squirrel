import AppKit

/// The menu bar while the window is open; window commands act on the window's selection.
@MainActor
enum MainMenu {
    static func make(commands controller: MainMenuController) -> NSMenu {
        let mainMenu = NSMenu()
        let hideOthers = item("Andere ausblenden", #selector(NSApplication.hideOtherApplications(_:)), key: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        let services = NSMenu(title: "Dienste")
        let servicesItem = NSMenuItem(title: "Dienste", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        mainMenu.addItem(
            submenu(
                "Backup-Squirrel",
                [
                    item("Über Backup-Squirrel", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
                    .separator(),
                    servicesItem,
                    .separator(),
                    item("Backup-Squirrel ausblenden", #selector(NSApplication.hide(_:)), key: "h"),
                    hideOthers,
                    item("Alle einblenden", #selector(NSApplication.unhideAllApplications(_:))),
                    .separator(),
                    item("Backup-Squirrel beenden", #selector(NSApplication.terminate(_:)), key: "q"),
                ]))
        mainMenu.addItem(
            submenu(
                "Ablage",
                [
                    controller.item(.newPlan, key: "n"),
                    controller.item(.newTarget, key: "N"),
                    .separator(),
                    controller.item(.rename),
                    controller.item(.delete),
                    .separator(),
                    item("Schließen", #selector(NSWindow.performClose(_:)), key: "w"),
                ]))
        mainMenu.addItem(
            submenu(
                "Bearbeiten",
                [
                    item("Widerrufen", Selector(("undo:")), key: "z"),
                    item("Wiederholen", Selector(("redo:")), key: "Z"),
                    .separator(),
                    item("Ausschneiden", #selector(NSText.cut(_:)), key: "x"),
                    item("Kopieren", #selector(NSText.copy(_:)), key: "c"),
                    item("Einsetzen", #selector(NSText.paste(_:)), key: "v"),
                    item("Alles auswählen", #selector(NSText.selectAll(_:)), key: "a"),
                ]))
        mainMenu.addItem(
            submenu(
                "Darstellung",
                [
                    controller.item(.toggleSidebar, key: "s", modifiers: [.command, .control]),
                    controller.item(.toggleInspector, key: "i", modifiers: [.command, .option]),
                ]))
        mainMenu.addItem(
            submenu(
                "Sicherung",
                [
                    controller.item(.backUpNow),
                    controller.item(.checkNow),
                    .separator(),
                    controller.item(.cancelRun, key: "."),
                ]))
        let window = submenu(
            "Fenster",
            [
                item("Im Dock ablegen", #selector(NSWindow.performMiniaturize(_:)), key: "m"),
                item("Zoomen", #selector(NSWindow.performZoom(_:))),
            ])
        mainMenu.addItem(window)
        NSApp.windowsMenu = window.submenu
        return mainMenu
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        menu.items = items
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }
}

@MainActor
final class MainMenuController: NSObject, NSMenuItemValidation {
    private let commands: () -> WindowCommands?
    private let perform: (WindowCommand) -> Void

    /// `commands` is nil while the window is closed.
    init(commands: @escaping () -> WindowCommands?, perform: @escaping (WindowCommand) -> Void) {
        self.commands = commands
        self.perform = perform
    }

    func item(_ command: WindowCommand, key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(
            title: WindowCommands(state: BackupState(plans: [], targets: [], runs: [], now: .now)).title(of: command),
            action: #selector(performCommand(_:)), keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
        item.target = self
        return item
    }

    @objc private func performCommand(_ sender: NSMenuItem) {
        guard let command = sender.identifier.flatMap({ WindowCommand(rawValue: $0.rawValue) }) else { return }
        perform(command)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = menuItem.identifier.flatMap({ WindowCommand(rawValue: $0.rawValue) }) else { return true }
        guard let commands = commands() else { return false }
        menuItem.title = commands.title(of: command)
        return commands.isEnabled(command)
    }
}
