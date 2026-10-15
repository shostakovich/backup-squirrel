import AppKit
import SwiftUI

/// AppKit owns the window because `NSHostingSceneRepresentation` cannot present `Window` scenes from AppKit code.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let defaultContentSize = NSSize(width: 1280, height: 760)
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    init(model: AppModel, router: WindowRouter) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize), styleMask: Self.styleMask,
            backing: .buffered, defer: true)
        Self.configure(window, model: model, router: router)
        super.init(window: window)
        window.delegate = self
        window.center()
        windowFrameAutosaveName = "MainWindow"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    static func configure(_ window: NSWindow, model: AppModel, router: WindowRouter) {
        let hostingController = NSHostingController(rootView: MainView(model: model, router: router))
        hostingController.sceneBridgingOptions = [.title, .toolbars]
        hostingController.sizingOptions = [.minSize]
        window.contentViewController = hostingController
        window.setContentSize(defaultContentSize)
        window.toolbarStyle = .unified
        // A utility window gains nothing from a full-screen space of its own.
        window.collectionBehavior.insert(.fullScreenNone)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
    }

    func present() {
        let wasVisible = window?.isVisible ?? false
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if !wasVisible, let window { Self.clearInitialFocus(of: window) }
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// AppKit focuses the first text field of a newly shown window and selects its text, which invites accidental edits.
    static func clearInitialFocus(of window: NSWindow) {
        window.makeFirstResponder(nil)
    }
}
