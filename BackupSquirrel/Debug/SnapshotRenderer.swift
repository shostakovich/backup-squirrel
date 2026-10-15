#if DEBUG
    import AppKit
    import SwiftUI

    /// Run with `-renderSnapshots <directory>`; needs no screen recording permission.
    @MainActor
    struct SnapshotRenderer {
        static let calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
            calendar.locale = Locale(identifier: "de_DE")
            return calendar
        }()

        static let referenceDate: Date =
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 13, minute: 20)) ?? Date()

        private static let appearances: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]

        let directory: URL

        func renderAll() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            renderMenuBarIcons()
            renderAppIcons()
            renderMenuDumps()
            renderMainMenuDumps()
            Self.pretendToBeActive()
            renderWindows()
            renderAccessibilityVariants()
            renderSetupSheets()
            verifyLiveMenuUpdates()
        }

        /// Switches and table selections ask the app, not the window, whether to draw active.
        private static func pretendToBeActive() {
            typealias SetActive = @convention(c) (AnyObject, Selector, Bool) -> Void
            let selector = Selector(("setIsActive:"))
            guard NSApp.responds(to: selector), let method = NSApp.method(for: selector) else { return }
            unsafeBitCast(method, to: SetActive.self)(NSApp, selector, true)
        }

        private func model(_ scenario: SampleScenario, system: SystemState? = nil) -> AppModel {
            scenario.makeModel(
                now: Self.referenceDate,
                calendar: Self.calendar,
                currentDate: { Self.referenceDate },
                inspectSystem: system.map { system in { system } },
                executor: SimulatedRunExecutor(tick: .seconds(3600))
            )
        }

        private func settle(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        // MARK: Windows

        private struct WindowShot {
            var name: String
            var scenario: SampleScenario
            var selection: SidebarItem?
            /// Tall enough to show every section of a plan or target page at once.
            var height: CGFloat = 720
            var filter = HistoryFilter()
            var selectRun: ((AppModel) -> Run.ID?)?
        }

        private func renderWindows() {
            let pageHeight: CGFloat = 1300
            let home = SidebarItem.plan(SampleData.homePlanID)
            let data = SidebarItem.plan(SampleData.dataPlanID)
            let target = SidebarItem.target(SampleData.storageBoxID)
            let shots = [
                WindowShot(name: "plan-healthy", scenario: .idle, selection: home, height: pageHeight),
                WindowShot(name: "plan-running", scenario: .running, selection: home, height: pageHeight),
                WindowShot(name: "plan-failed", scenario: .error, selection: home, height: pageHeight),
                WindowShot(name: "plan-overdue", scenario: .overdue, selection: data, height: pageHeight),
                WindowShot(name: "plan-manual-only", scenario: .manual, selection: data, height: pageHeight),
                WindowShot(name: "plan-incomplete", scenario: .incomplete, selection: data, height: pageHeight),
                WindowShot(name: "plan-unreadable-files", scenario: .warning, selection: home, height: pageHeight),
                WindowShot(name: "plan-uptime-kuma-failed", scenario: .warning, selection: data, height: pageHeight),
                WindowShot(
                    name: "plan-no-full-disk-access", scenario: .noFullDiskAccess, selection: home, height: pageHeight),
                WindowShot(name: "plan-no-login-item", scenario: .noLoginItem, selection: home),
                WindowShot(name: "plan-notifications-denied", scenario: .notificationsDenied, selection: home),
                WindowShot(name: "target-healthy", scenario: .idle, selection: target, height: 1240),
                WindowShot(name: "target-check-overdue", scenario: .checkOverdue, selection: target, height: 1240),
                WindowShot(name: "target-check-errors", scenario: .checkErrors, selection: target, height: 1240),
                WindowShot(name: "target-check-failed", scenario: .checkFailed, selection: target, height: 1240),
                WindowShot(
                    name: "history-inspector", scenario: .warning, selection: .history,
                    selectRun: { model in model.runs.last { $0.status == .warning }?.id }),
                WindowShot(
                    name: "history-unreadable-no-full-disk-access", scenario: .noFullDiskAccess, selection: .history,
                    selectRun: { model in model.runs.last { $0.status == .warning }?.id }),
                WindowShot(
                    name: "history-only-problems", scenario: .error, selection: .history,
                    filter: HistoryFilter(onlyProblems: true),
                    selectRun: { model in model.runs.last { $0.status == .failed }?.id }),
                WindowShot(
                    name: "history-check-errors", scenario: .checkErrors, selection: .history,
                    filter: HistoryFilter(scope: .target(SampleData.storageBoxID)),
                    selectRun: { model in model.runs.last { $0.kind == .check }?.id }),
                WindowShot(
                    name: "history-days-without-runs", scenario: .overdue, selection: .history,
                    selectRun: { model in model.runs.last { $0.planID == SampleData.dataPlanID }?.id }),
                WindowShot(name: "history-empty", scenario: .empty, selection: .history),
                WindowShot(name: "not-set-up", scenario: .empty, selection: nil),
            ]
            for shot in shots {
                for (appearance, suffix) in Self.appearances {
                    render(shot, appearance: appearance, name: "window-\(shot.name)-\(suffix)")
                }
            }
        }

        private func render(_ shot: WindowShot, appearance: NSAppearance.Name, name: String) {
            let model = model(shot.scenario)
            settle(0.1)
            let router = WindowRouter(selection: shot.selection)
            router.historyFilter = shot.filter
            router.selectedRunID = shot.selectRun?(model)
            router.isInspectorPresented = shot.selectRun != nil
            let size = NSSize(width: MainWindowController.defaultContentSize.width, height: shot.height)
            renderWindow(model: model, router: router, size: size, appearance: appearance, name: name)
        }

        /// Increase Contrast and Reduce Transparency, which the renderer imitates for its own windows only.
        private func renderAccessibilityVariants() {
            let plan = WindowShot(name: "plan", scenario: .idle, selection: .plan(SampleData.homePlanID), height: 1300)
            let history = WindowShot(
                name: "history", scenario: .warning, selection: .history,
                selectRun: { model in model.runs.last { $0.status == .warning }?.id })
            let variants: [(String, Bool, Bool, [(NSAppearance.Name, String)])] = [
                (
                    "increase-contrast", true, false,
                    [(.accessibilityHighContrastAqua, "light"), (.accessibilityHighContrastDarkAqua, "dark")]
                ),
                ("reduce-transparency", false, true, Self.appearances),
            ]
            for (variant, contrast, transparency, appearances) in variants {
                AccessibilityDisplayOverride.apply(increaseContrast: contrast, reduceTransparency: transparency)
                for shot in [plan, history] {
                    for (appearance, suffix) in appearances {
                        render(shot, appearance: appearance, name: "window-\(shot.name)-\(variant)-\(suffix)")
                    }
                }
            }
            AccessibilityDisplayOverride.apply(increaseContrast: false, reduceTransparency: false)
        }

        private struct SheetShot {
            var name: String
            var step: TargetSetup.Step
            var repository = RepositoryDetection.notFound
            var configure: (TargetSetup) -> Void = { _ in }
        }

        private func renderSetupSheets() {
            let shots = [
                SheetShot(name: "1-connection", step: .connection),
                SheetShot(name: "2-key", step: .key),
                SheetShot(name: "3-test-new-repository", step: .test),
                SheetShot(name: "3-test-existing-repository", step: .test, repository: .found(snapshots: 37)),
                SheetShot(name: "4-password-new", step: .password) { setup in
                    var generator = SeededGenerator(seed: 7)
                    setup.generatePassword(using: &generator)
                    setup.isPasswordStored = true
                },
                SheetShot(name: "4-password-existing-wrong", step: .password, repository: .found(snapshots: 37)) {
                    setup in
                    setup.password = "falsches-passwort"
                    setup.passwordCheck = .wrong
                },
                SheetShot(name: "5-create-new", step: .create),
                SheetShot(name: "5-create-existing", step: .create, repository: .found(snapshots: 37)),
                SheetShot(name: "6-plan", step: .plan) { setup in
                    setup.planFolders = [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)]
                },
                SheetShot(name: "7-permissions", step: .permissions),
            ]
            for shot in shots {
                for (appearance, suffix) in Self.appearances {
                    let model = model(
                        .empty, system: SystemState(hasFullDiskAccess: false, notifications: .notDetermined))
                    let setup = TargetSetup(target: model.makeTargetDraft(), isOnboarding: true)
                    if shot.step != .connection {
                        setup.target.host = "u123456.your-storagebox.de"
                        setup.target.user = "u123456-sub1"
                        setup.target.path = "/home/restic/mac"
                        setup.finishConnectionTest(.succeeded)
                        setup.repository = shot.repository
                    }
                    if shot.step == .permissions {
                        model.addTarget(setup.target, password: "beispiel")
                        setup.createdPlanID = model.addPlan(
                            name: "Home-Verzeichnis", targetID: setup.target.id,
                            sourceFolders: [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)])
                    }
                    setup.step = shot.step
                    shot.configure(setup)
                    let router = WindowRouter(selection: nil)
                    router.targetSetup = setup
                    renderWindow(
                        model: model, router: router, size: MainWindowController.defaultContentSize,
                        appearance: appearance, name: "sheet-new-target-\(shot.name)-\(suffix)")
                }
            }
        }

        private func renderWindow(
            model: AppModel, router: WindowRouter, size: NSSize, appearance: NSAppearance.Name, name: String
        ) {
            let window = OffscreenWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: MainWindowController.styleMask, backing: .buffered, defer: false)
            MainWindowController.configure(window, model: model, router: router)
            window.setContentSize(size)
            window.appearance = NSAppearance(named: appearance)
            window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
            window.orderFrontRegardless()
            window.makeKey()
            settle(0.2)
            MainWindowController.clearInitialFocus(of: window)
            settle(0.3)
            if router.selectedRunID != nil, let table = runTable(in: window.contentView) {
                window.makeFirstResponder(table)
            }
            settle(1.2)
            if let sheet = window.attachedSheet {
                // AppKit pulls a window with a sheet onto the screen, where its image comes back blank.
                window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
                sheet.makeFirstResponder(nil)
                settle(0.5)
            }
            var image = capture(window)
            if let sheet = window.attachedSheet, let sheetImage = WindowServerCapture.image(of: sheet),
                let base = image
            {
                image = overlay(sheetImage, at: sheet.frame, on: base, frame: window.frame)
            }
            write(image, name)
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            window.close()
        }

        /// The history table, not the sidebar, which is a table as well.
        private func runTable(in view: NSView?) -> NSTableView? {
            guard let view else { return nil }
            if let table = view as? NSTableView, table.numberOfColumns > 2 { return table }
            for subview in view.subviews {
                if let table = runTable(in: subview) { return table }
            }
            return nil
        }

        /// A sheet is a window of its own; this puts it back where it hangs on its parent.
        private func overlay(_ sheet: CGImage, at sheetFrame: NSRect, on base: CGImage, frame: NSRect) -> CGImage? {
            guard let context = bitmapContext(width: base.width, height: base.height) else { return base }
            let scale = CGFloat(base.width) / frame.width
            context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
            let origin = CGPoint(x: (sheetFrame.minX - frame.minX) * scale, y: (sheetFrame.minY - frame.minY) * scale)
            context.draw(sheet, in: CGRect(origin: origin, size: CGSize(width: sheet.width, height: sheet.height)))
            return context.makeImage()
        }

        /// The window server's image of our own window needs no permission and includes materials `cacheDisplay` misses.
        private func capture(_ window: NSWindow) -> CGImage? {
            if let image = WindowServerCapture.image(of: window) { return image }
            guard let frameView = window.contentView?.superview,
                let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
            else { return nil }
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            }
            return bitmap.cgImage
        }

        // MARK: Icons

        private func renderMenuBarIcons() {
            let states: [(String, MenuBarIconState)] = [
                ("idle", .idle),
                ("running-0", .running(fraction: 0)),
                ("running-12", .running(fraction: 0.12)),
                ("running-43", .running(fraction: 0.43)),
                ("running-85", .running(fraction: 0.85)),
                ("running-100", .running(fraction: 1)),
                ("warning", .warning),
                ("error", .error),
                ("not-set-up-dimmed", .notSetUp),
            ]
            let light = (background: NSColor(white: 0.93, alpha: 1), foreground: NSColor(white: 0, alpha: 0.85))
            let dark = (background: NSColor(white: 0.17, alpha: 1), foreground: NSColor.white)
            var overviewRows: [CGImage] = []
            for (name, state) in states {
                var row: [CGImage] = []
                let alpha = state == .notSetUp ? MenuBarIcon.dimmedAlpha : 1
                for (scheme, colors) in [("light", light), ("dark", dark)] {
                    let foreground = colors.foreground.withAlphaComponent(colors.foreground.alphaComponent * alpha)
                    for scale in [1.0, 2.0, 8.0] {
                        guard let icon = MenuBarIcon.render(state, scale: scale),
                            let image = composite(
                                icon, foreground: foreground, background: colors.background, padding: scale * 3)
                        else { continue }
                        write(image, "menubar-\(name)-\(Int(scale))x-\(scheme)")
                        row.append(image)
                    }
                }
                if let rowImage = hstack(row, spacing: 12, background: .white) { overviewRows.append(rowImage) }
            }
            if let overview = vstack(overviewRows, spacing: 12, background: .white) {
                write(overview, "menubar-overview")
            }

            let systemSymbols = ["wifi", "clock", "externaldrive"].compactMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                    .withSymbolConfiguration(MenuBarIcon.configuration)
            }
            let comparedStates: [MenuBarIconState] = [.idle, .running(fraction: 0.43), .warning, .error]
            var comparisonRows: [CGImage] = []
            for colors in [light, dark] {
                for scale in [1.0, 2.0, 8.0] {
                    let icons =
                        systemSymbols.compactMap { MenuBarIcon.render($0, scale: scale) }
                        + comparedStates.compactMap { MenuBarIcon.render($0, scale: scale) }
                    let images = icons.compactMap {
                        composite($0, foreground: colors.foreground, background: colors.background, padding: scale * 3)
                    }
                    if let row = hstack(images, spacing: 12, background: .white) { comparisonRows.append(row) }
                }
            }
            if let comparison = vstack(comparisonRows, spacing: 12, background: .white) {
                write(comparison, "menubar-comparison")
            }
        }

        private func renderAppIcons() {
            let sizes = [1024, 128, 32]
            let assetIcon = NSImage(named: "AppIcon").map { icon in sizes.compactMap { draw(icon, pixels: $0) } } ?? []
            let systemIcon = withFreshBundleCopy { path in
                sizes.compactMap { draw(NSWorkspace.shared.icon(forFile: path), pixels: $0) }
            }
            for (name, images) in [("asset", assetIcon), ("system", systemIcon)] {
                for image in images {
                    let size = image.width
                    write(image, "appicon-\(name)-\(size)")
                    write(
                        composite(image, background: NSColor(white: 0.93, alpha: 1)), "appicon-\(name)-\(size)-on-light"
                    )
                    write(
                        composite(image, background: NSColor(white: 0.12, alpha: 1)), "appicon-\(name)-\(size)-on-dark")
                }
            }
        }

        /// Icon Services caches icons per path, so a rebuilt app at the same path can show a stale icon.
        private func withFreshBundleCopy(_ body: (String) -> [CGImage]) -> [CGImage] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let copy = folder.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: copy)
            } catch {
                return []
            }
            return body(copy.path)
        }

        // MARK: Menus

        private func renderMenuDumps() {
            for scenario in SampleScenario.allCases {
                let model = model(scenario)
                settle(0.1)
                let state = model.state
                let entries = StatusMenu(calendar: Self.calendar).entries(for: state)
                let menu = MenuRenderer.makeMenu(entries, target: nil)
                let iconState = StatusEvaluator(calendar: Self.calendar).iconState(for: state)
                let tooltip = StatusText(calendar: Self.calendar).tooltip(for: state)
                let now = RelativeDateText(calendar: Self.calendar).string(
                    for: Self.referenceDate, now: Self.referenceDate)
                var lines = [
                    "Scenario: \(scenario.rawValue)",
                    "Now: \(now) (2026-10-14, Europe/Berlin)",
                    "Icon: \(iconState)" + (iconState == .notSetUp ? " (appearsDisabled)" : ""),
                    "Tooltip: \(tooltip)",
                    "VoiceOver: Backup-Squirrel: \(tooltip)",
                    "",
                ]
                lines += dump(menu, entries: entries, depth: 0)
                let alerts = AlertPlanner(calendar: Self.calendar).alerts(in: state)
                lines += ["", "Notifications when these problems first appear:"]
                lines +=
                    alerts.isEmpty
                    ? ["(none)"]
                    : alerts.flatMap { alert in
                        [
                            "• \(alert.title)", "  \(alert.body)",
                            "  [Button „\(alert.style.title)“ → \(alert.command)] [Klick → \(alert.route)]",
                        ]
                    }
                writeText(lines.joined(separator: "\n") + "\n", "menu-\(scenario.rawValue)")
            }
        }

        /// What each menu bar menu offers in typical window states.
        private func renderMainMenuDumps() {
            let idle = model(.idle)
            let running = model(.running)
            settle(0.1)
            let states: [(String, WindowCommands)] = [
                ("plan", WindowCommands(selection: .plan(SampleData.homePlanID), state: idle.state)),
                (
                    "plan-while-running",
                    WindowCommands(selection: .plan(SampleData.dataPlanID), state: running.state)
                ),
                ("target", WindowCommands(selection: .target(SampleData.storageBoxID), state: idle.state)),
                ("history", WindowCommands(selection: .history, state: idle.state)),
                (
                    "history-inspector-hidden-sidebar-hidden",
                    WindowCommands(
                        selection: .history, isSidebarVisible: false, isInspectorVisible: false, state: idle.state)
                ),
                (
                    "sheet-open",
                    WindowCommands(selection: .plan(SampleData.homePlanID), isSheetOpen: true, state: idle.state)
                ),
            ]
            for (name, commands) in states {
                let controller = MainMenuController(commands: { commands }, perform: { _ in })
                let menu = MainMenu.make(commands: controller)
                var lines = ["Window state: \(name)", ""]
                for top in menu.items {
                    lines.append(top.title)
                    for item in top.submenu?.items ?? [] {
                        if item.isSeparatorItem {
                            lines.append("    ────────")
                            continue
                        }
                        let isEnabled = controller.validateMenuItem(item)
                        var line = "    \(item.title)"
                        if !item.keyEquivalent.isEmpty { line += "   \(shortcut(item))" }
                        if item.target === controller, !isEnabled { line += "   [deaktiviert]" }
                        lines.append(line)
                    }
                }
                writeText(lines.joined(separator: "\n") + "\n", "mainmenu-\(name)")
            }
        }

        private func dump(_ menu: NSMenu, entries: [MenuEntry], depth: Int) -> [String] {
            let indent = String(repeating: "    ", count: depth)
            var lines: [String] = []
            for (item, entry) in zip(menu.items, entries) {
                if item.isSeparatorItem {
                    lines.append(indent + "────────")
                    continue
                }
                if item.isSectionHeader {
                    lines.append(indent + "[Abschnitt] \(item.title)")
                    continue
                }
                var line = indent + item.title
                var attributes: [String] = []
                if !item.isEnabled { attributes.append("deaktiviert") }
                if let action = entry.action { attributes.append("→ \(action)") }
                if let symbol = entry.symbol {
                    let missing = NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil) == nil
                    let description = item.image?.accessibilityDescription ?? "OHNE BESCHREIBUNG"
                    attributes.append(
                        "Symbol \(symbol.name) (\(symbol.tint), \(symbol.rendering), „\(description)“)"
                            + (missing ? " FEHLT" : ""))
                }
                if !item.keyEquivalent.isEmpty {
                    attributes.append("Kurzbefehl \(shortcut(item))")
                }
                if item.submenu != nil { attributes.append("Untermenü") }
                if !attributes.isEmpty { line += "   [" + attributes.joined(separator: ", ") + "]" }
                lines.append(line)
                if let subtitle = item.subtitle { lines.append(indent + "    ↳ \(subtitle)") }
                if let submenu = item.submenu {
                    lines += dump(submenu, entries: entry.children, depth: depth + 1)
                }
            }
            return lines
        }

        private func shortcut(_ item: NSMenuItem) -> String {
            var text = ""
            if item.keyEquivalentModifierMask.contains(.control) { text += "⌃" }
            if item.keyEquivalentModifierMask.contains(.option) { text += "⌥" }
            if item.keyEquivalentModifierMask.contains(.shift) || item.keyEquivalent != item.keyEquivalent.lowercased()
            {
                text += "⇧"
            }
            if item.keyEquivalentModifierMask.contains(.command) { text += "⌘" }
            return text + item.keyEquivalent.uppercased()
        }

        private func verifyLiveMenuUpdates() {
            let model = SampleScenario.running.makeModel(
                now: Self.referenceDate, calendar: Self.calendar, currentDate: { Self.referenceDate },
                executor: SimulatedRunExecutor(tick: .milliseconds(200)))
            let controller = StatusItemController(model: model) { _ in }
            settle(0.5)
            let sampler = MenuSampler(menu: controller.menu)
            let delays = [0.4, 0.8, 1.2, 1.6, 2.0, 2.4]
            for delay in delays {
                let timer = Timer(timeInterval: delay, repeats: false) { _ in
                    MainActor.assumeIsolated { sampler.sample(after: delay, close: delay == delays.last) }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
            let openedAt = Date()
            controller.menu.popUp(positioning: nil, at: NSPoint(x: 200, y: 400), in: nil)
            let trackedFor = Date().timeIntervalSince(openedAt)
            controller.remove()
            model.cancelActiveRun()
            let distinct = Set(sampler.samples.map(\.text)).count
            let passed = sampler.samples.count == delays.count && distinct > 2
            let report =
                ["Menu stayed open for \(String(format: "%.1f", trackedFor)) s; samples taken by timers meanwhile:"]
                + sampler.samples.map { "\(String(format: "%.1f", $0.delay)) s: \($0.text)" }
                + ["Distinct samples: \(distinct) of \(sampler.samples.count)"]
                + ["Live update while open: \(passed ? "yes" : "no")"]
            writeText(report.joined(separator: "\n") + "\n", "menu-live-update")
        }

        // MARK: Bitmaps

        private func composite(_ icon: CGImage, foreground: NSColor, background: NSColor, padding: CGFloat) -> CGImage?
        {
            let width = icon.width + Int(padding * 2)
            let height = icon.height + Int(padding * 2)
            guard let context = bitmapContext(width: width, height: height) else { return nil }
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let rect = CGRect(x: padding, y: padding, width: CGFloat(icon.width), height: CGFloat(icon.height))
            guard let tinted = tint(icon, with: foreground) else { return nil }
            context.draw(tinted, in: rect)
            return context.makeImage()
        }

        private func composite(_ image: CGImage, background: NSColor) -> CGImage? {
            guard let context = bitmapContext(width: image.width, height: image.height) else { return nil }
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return context.makeImage()
        }

        /// Keeps the icon's alpha, as the menu bar does with template images.
        private func tint(_ image: CGImage, with color: NSColor) -> CGImage? {
            guard let context = bitmapContext(width: image.width, height: image.height) else { return nil }
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.draw(image, in: rect)
            context.setBlendMode(.sourceIn)
            context.setFillColor(color.cgColor)
            context.fill(rect)
            return context.makeImage()
        }

        private func draw(_ image: NSImage, pixels: Int) -> CGImage? {
            guard let context = bitmapContext(width: pixels, height: pixels) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            return context.makeImage()
        }

        private func hstack(_ images: [CGImage], spacing: Int, background: NSColor) -> CGImage? {
            let width = images.map(\.width).reduce(0, +) + spacing * (images.count + 1)
            let height = (images.map(\.height).max() ?? 0) + spacing * 2
            guard let context = bitmapContext(width: width, height: height) else { return nil }
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var x = spacing
            for image in images {
                context.draw(
                    image, in: CGRect(x: x, y: (height - image.height) / 2, width: image.width, height: image.height))
                x += image.width + spacing
            }
            return context.makeImage()
        }

        private func vstack(_ images: [CGImage], spacing: Int, background: NSColor) -> CGImage? {
            let width = images.map(\.width).max() ?? 0
            let height = images.map(\.height).reduce(0, +)
            guard let context = bitmapContext(width: width, height: height) else { return nil }
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var y = height
            for image in images {
                y -= image.height
                context.draw(image, in: CGRect(x: 0, y: y, width: image.width, height: image.height))
            }
            return context.makeImage()
        }

        private func bitmapContext(width: Int, height: Int) -> CGContext? {
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            return CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }

        private func write(_ image: CGImage?, _ name: String) {
            guard let image else { return }
            write(NSBitmapImageRep(cgImage: image), name)
        }

        private func write(_ bitmap: NSBitmapImageRep, _ name: String) {
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: directory.appendingPathComponent("\(name).png"))
        }

        private func writeText(_ text: String, _ name: String) {
            try? text.write(to: directory.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    private final class MenuSampler {
        let menu: NSMenu
        private(set) var samples: [(delay: Double, text: String)] = []

        init(menu: NSMenu) {
            self.menu = menu
        }

        func sample(after delay: Double, close: Bool) {
            let status = menu.items.first
            let row = menu.items.first { $0.identifier?.rawValue == "plan.\(SampleData.homePlanID)" }
            samples.append(
                (
                    delay,
                    "\(status?.title ?? "") | \(status?.subtitle ?? "") | \(row?.subtitle ?? "") | \(menu.items.count) items"
                ))
            if close { menu.cancelTracking() }
        }
    }

    @MainActor
    private enum WindowServerCapture {
        private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

        static func image(of window: NSWindow) -> CGImage? {
            guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
                let symbol = dlsym(handle, "CGWindowListCreateImage")
            else { return nil }
            let create = unsafeBitCast(symbol, to: CreateImage.self)
            let includingWindow: UInt32 = 1 << 3
            let boundsIgnoreFraming: UInt32 = 1 << 0
            let bestResolution: UInt32 = 1 << 3
            return create(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?
                .takeRetainedValue()
        }
    }

    /// Draws like the key window of the active app, which a renderer started from a shell can never be.
    private final class OffscreenWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var canBecomeKey: Bool { true }

        override init(
            contentRect: NSRect, styleMask style: NSWindow.StyleMask,
            backing backingStoreType: NSWindow.BackingStoreType,
            defer flag: Bool
        ) {
            super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
            let forceActiveControls = Selector(("_setForceActiveControls:"))
            if responds(to: forceActiveControls) { perform(forceActiveControls, with: true) }
        }

        @objc(_hasActiveAppearance) func hasActiveAppearance() -> Bool { true }

        @objc(_hasActiveControls) func hasActiveControls() -> Bool { true }

        @objc(_hasActiveAppearanceIgnoringKeyFocus) func hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }

        @objc(_hasActiveAppearanceForStandardWindowButton:)
        func hasActiveAppearance(forStandardWindowButton button: Int) -> Bool { true }

        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }
    }

    /// Swaps the system's accessibility display settings for the renderer's windows.
    @MainActor
    private enum AccessibilityDisplayOverride {
        private static var isInstalled = false
        static var increaseContrast = false
        static var reduceTransparency = false

        static func apply(increaseContrast: Bool, reduceTransparency: Bool) {
            install()
            Self.increaseContrast = increaseContrast
            Self.reduceTransparency = reduceTransparency
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: NSWorkspace.shared)
        }

        private static func install() {
            guard !isInstalled else { return }
            isInstalled = true
            for (original, replacement) in [
                (
                    #selector(getter: NSWorkspace.accessibilityDisplayShouldIncreaseContrast),
                    #selector(getter: NSWorkspace.snapshotIncreaseContrast)
                ),
                (
                    #selector(getter: NSWorkspace.accessibilityDisplayShouldReduceTransparency),
                    #selector(getter: NSWorkspace.snapshotReduceTransparency)
                ),
            ] {
                guard let originalMethod = class_getInstanceMethod(NSWorkspace.self, original),
                    let replacementMethod = class_getInstanceMethod(NSWorkspace.self, replacement)
                else { continue }
                method_exchangeImplementations(originalMethod, replacementMethod)
            }
        }
    }

    extension NSWorkspace {
        @objc fileprivate var snapshotIncreaseContrast: Bool {
            MainActor.assumeIsolated { AccessibilityDisplayOverride.increaseContrast }
        }

        @objc fileprivate var snapshotReduceTransparency: Bool {
            MainActor.assumeIsolated { AccessibilityDisplayOverride.reduceTransparency }
        }
    }

    /// Repeatable "random" values, so a generated password looks the same in every snapshot.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }
#endif
