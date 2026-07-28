import ServiceManagement
import SwiftUI

/// The window you get from the menu bar's "Settings…" item.
struct SettingsView: View {

    @ObservedObject var store: ClipboardStore

    /// `@AppStorage` is a tiny wrapper over `UserDefaults`: read it like a
    /// normal value, and writing to it both saves to disk and redraws the view.
    @AppStorage("maxItems") private var maxItems = 200
    @AppStorage("autoPaste") private var autoPaste = true

    @AppStorage("syncEnabled") private var syncEnabled = false
    @AppStorage("syncFolderPath") private var syncFolderPath = ""

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityGranted = Paster.canAutoPaste
    @State private var showingClearConfirmation = false

    var body: some View {
        Form {
            Section("History") {
                Stepper(value: $maxItems, in: 20...2000, step: 20) {
                    Text("Keep the last \(maxItems) items")
                }
                Text("Pinned items are always kept, no matter the limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Clear history (keep pinned)…") {
                    showingClearConfirmation = true
                }
                .confirmationDialog("Clear clipboard history?",
                                    isPresented: $showingClearConfirmation) {
                    Button("Clear", role: .destructive) { store.clearAll(keepPinned: true) }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Pinned items will be kept. This cannot be undone.")
                }
            }

            Section("Behaviour") {
                Toggle("Paste automatically after picking an item", isOn: $autoPaste)

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, wantsLaunch in
                        do {
                            if wantsLaunch {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            NSLog("ClipboardHistory: login item failed — \(error)")
                            launchAtLogin = !wantsLaunch   // put the switch back
                        }
                    }
            }

            Section("Sync between Macs") {
                Toggle("Sync automatically via iCloud", isOn: iCloudSyncBinding)
                    .disabled(!Self.iCloudDriveExists && !iCloudSyncBinding.wrappedValue)

                if Self.iCloudDriveExists {
                    Text("One switch, no setup — history syncs through your iCloud "
                         + "Drive. Turn this on on your other Mac too. Sync only adds: "
                         + "deleting here does not delete there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("iCloud Drive is not enabled on this Mac "
                         + "(System Settings → Apple ID → iCloud).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                DisclosureGroup("Advanced: use a custom folder") {
                    HStack {
                        Text(usingCustomFolder
                             ? (syncFolderPath as NSString).abbreviatingWithTildeInPath
                             : "No custom folder chosen")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(usingCustomFolder ? .primary : .secondary)
                        Spacer()
                        Button("Choose Folder…") { chooseSyncFolder() }
                    }
                    Text("Pick the same folder on every Mac — any folder that Dropbox, "
                         + "Google Drive or similar mirrors between machines.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Permissions") {
                HStack {
                    Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibilityGranted ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accessibilityGranted ? "Accessibility access granted"
                                                  : "Accessibility access needed for auto-paste")
                        Text("Without it, picking an item still copies it — you just press ⌘V yourself.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !accessibilityGranted {
                    HStack {
                        Button("Request access") { Paster.requestAccessibilityPermission() }
                        Button("Open System Settings") { Paster.openAccessibilitySettings() }
                    }
                }
                Button("Re-check") { accessibilityGranted = Paster.canAutoPaste }
            }

            Section("Shortcut") {
                LabeledContent("Show history", value: "⌘⇧V")
                Text("Fixed for now — a shortcut recorder is a good next feature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Explicit height: a grouped Form lives in a scroll view, which has no
        // intrinsic height — without this the settings window opens collapsed.
        .frame(width: 460, height: 620)
        .onAppear { accessibilityGranted = Paster.canAutoPaste }
        // Re-check on a slow tick so the row flips to "granted" by itself when
        // the user returns from System Settings.
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            accessibilityGranted = Paster.canAutoPaste
        }
    }

    // MARK: - Sync helpers

    /// iCloud Drive's on-disk home. The same path exists on every Mac signed
    /// into iCloud, which is what makes zero-setup sync possible.
    private static let iCloudDrivePath =
        NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"

    private static var iCloudDriveExists: Bool {
        FileManager.default.fileExists(atPath: iCloudDrivePath)
    }

    private var iCloudSyncFolder: String { Self.iCloudDrivePath + "/ClipboardHistory" }

    private var usingCustomFolder: Bool {
        !syncFolderPath.isEmpty && syncFolderPath != iCloudSyncFolder
    }

    /// "On" means: sync enabled AND pointed at the well-known iCloud location.
    private var iCloudSyncBinding: Binding<Bool> {
        Binding(
            get: { syncEnabled && syncFolderPath == iCloudSyncFolder },
            set: { on in
                if on {
                    try? FileManager.default.createDirectory(
                        atPath: iCloudSyncFolder, withIntermediateDirectories: true)
                    syncFolderPath = iCloudSyncFolder
                    syncEnabled = true
                } else {
                    syncEnabled = false
                }
            })
    }

    private func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose the shared folder to sync clipboard history through."
        if panel.runModal() == .OK, let url = panel.url {
            syncFolderPath = url.path
            syncEnabled = true
        }
    }
}
