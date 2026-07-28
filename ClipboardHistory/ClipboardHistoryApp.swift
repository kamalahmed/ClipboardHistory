import SwiftUI

/// The entry point. `@main` tells Swift "start the program here".
///
/// A SwiftUI `App` is described by its `Scene`s. Ours only declares `Settings`,
/// which gives us a standard macOS settings window for free. All the interesting
/// window management (menu bar icon, popup panel) happens in `AppDelegate`,
/// because AppKit gives us far more control over a floating panel than SwiftUI does.
@main
struct ClipboardHistoryApp: App {

    /// Bridges the old AppKit lifecycle into SwiftUI. SwiftUI creates the
    /// delegate for us and keeps it alive for the life of the app.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(store: appDelegate.store)
        }
    }
}
