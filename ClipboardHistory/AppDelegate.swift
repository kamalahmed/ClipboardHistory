import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Wires everything together and owns the menu bar icon.
final class AppDelegate: NSObject, NSApplicationDelegate {

    let store = ClipboardStore()

    // Implicitly-unwrapped optionals (`!`) because these are created in
    // `applicationDidFinishLaunching`, not in `init`.
    private var monitor: ClipboardMonitor!
    private var panelController: PanelController!
    private var statusItem: NSStatusItem!
    private var hotKey: GlobalHotKey?
    private var syncManager: SyncManager!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `.accessory` = live in the menu bar only: no Dock icon, no app menu.
        // (Info.plist's LSUIElement does this too; setting it here is belt and braces.)
        NSApp.setActivationPolicy(.accessory)

        panelController = PanelController(store: store)
        panelController.onOpenSettings = { [weak self] in self?.openSettings() }

        monitor = ClipboardMonitor(store: store)
        monitor.start()

        setUpStatusItem()

        registerHotKey()

        // Re-register when the user picks a different shortcut in Settings.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.registeredPreset != HotKeyPreset.current else { return }
            self.registerHotKey()
        }

        syncManager = SyncManager(store: store)
        syncManager.start()

        // A menu bar app launches with no window, which looks like nothing
        // happened. The first time ever, show the panel so new users see it.
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.panelController.show()
            }
        }

        // `open -a ClipboardHistory --args --settings` — handy for testing.
        if CommandLine.arguments.contains("--settings") {
            openSettings()
        }
    }

    private var registeredPreset: HotKeyPreset?

    private func registerHotKey() {
        let preset = HotKeyPreset.current
        hotKey = nil   // deinit unregisters the old combo before we take the new one
        hotKey = GlobalHotKey(keyCode: preset.keyCode,
                              modifiers: preset.modifiers) { [weak self] in
            self?.panelController.toggle()
        }
        registeredPreset = preset

        if hotKey == nil {
            NSLog("ClipboardHistory: \(preset.label) is already taken by another app.")
        }
    }

    /// Re-launching the app while it's already running (double-click in Finder,
    /// `open -a ClipboardHistory`) shows the history panel instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        panelController.show()
        return false
    }

    // MARK: - Menu bar icon

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "doc.on.clipboard",
                               accessibilityDescription: "Clipboard History")
        button.image?.isTemplate = true   // adapts to light/dark menu bar
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// `@objc` exposes this to AppKit's old-style target/action machinery.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isRightClick {
            showMenu()
        } else {
            panelController.toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let open = NSMenuItem(title: "Show History",
                              action: #selector(showPanel),
                              keyEquivalent: "v")
        open.keyEquivalentModifierMask = [.command, .shift]
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let clear = NSMenuItem(title: "Clear History (keep pinned)",
                               action: #selector(clearHistory),
                               keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ClipboardHistory",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        // Attaching the menu then clicking the button is the standard trick for
        // "left click does something, right click opens a menu".
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showPanel() {
        panelController.show()
    }

    @objc private func clearHistory() {
        store.clearAll(keepPinned: true)
    }

    @objc private func openSettings() {
        // The floating panel sits above normal windows — close it first so the
        // settings window doesn't open underneath it.
        panelController.hide()

        // The SwiftUI `Settings` scene is opened via a private selector that
        // silently does nothing for `.accessory` apps on recent macOS, so we
        // own a plain window ourselves — same approach as the history panel.
        if settingsWindow == nil {
            // `contentViewController:` sizes the window to the SwiftUI view's
            // preferred size; a manual contentRect would start collapsed.
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: SettingsView(store: store)))
            window.title = "ClipboardHistory Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.center()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
