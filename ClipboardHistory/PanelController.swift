import AppKit
import SwiftUI

/// An `NSPanel` normally refuses keyboard focus. We want to type in the search
/// box, so we override `canBecomeKey`.
final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Shows and hides the floating history window, and performs the paste.
final class PanelController: NSObject, NSWindowDelegate {

    private let store: ClipboardStore
    private var panel: HistoryPanel?

    /// Whoever was in front before we appeared — we hand focus back to them
    /// after a paste so ⌘V lands in the right place.
    private var previousApp: NSRunningApplication?

    /// Set by AppDelegate; the panel's gear button calls this.
    var onOpenSettings: (() -> Void)?

    init(store: ClipboardStore) {
        self.store = store
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication

        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Rebuilding the SwiftUI view each time resets the search text and the
        // selection, which is what you want from a quick-launcher style popup.
        panel.contentView = NSHostingView(rootView: HistoryView(
            store: store,
            onPick: { [weak self] item in self?.paste(item) },
            onClose: { [weak self] in self?.hide() },
            onOpenSettings: { [weak self] in self?.onOpenSettings?() }
        ))

        position(panel)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Window plumbing

    private func makePanel() -> HistoryPanel {
        let panel = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Keep the red close button so there's a visible way out; minimise and
        // zoom make no sense for a quick-look popup, so those stay hidden.
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        return panel
    }

    /// Put the panel just below the mouse, clamped to stay on screen.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x - size.width / 2,
                             y: mouse.y - size.height - 8)

        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)

        panel.setFrameOrigin(origin)
    }

    /// Clicking anywhere else dismisses the popup.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: - Pasting

    private func paste(_ item: ClipItem) {
        Paster.copyToPasteboard(item, store: store)
        hide()

        let autoPaste = UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true
        guard autoPaste, Paster.canAutoPaste else { return }

        previousApp?.activate(from: .current)
        // A beat, so the other app is really frontmost before the keystroke lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Paster.sendCommandV()
        }
    }
}
