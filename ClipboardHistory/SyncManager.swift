import AppKit

/// Syncs history between Macs through a shared folder (iCloud Drive, Dropbox,
/// a network share — anything that mirrors a folder between machines).
///
/// The design deliberately avoids conflicts: every device writes ONLY its own
/// file, `devices/<deviceID>.json`, and *reads* everyone else's. No file ever
/// has two writers, so the sync service never has to merge — we do, by content
/// hash, the same way the store already de-duplicates.
///
/// Layout inside the chosen folder:
/// ```
/// devices/<deviceID>.json   one per Mac — that Mac's full history
/// images/<uuid>.png         image clippings, shared (names are UUIDs, no clashes)
/// ```
///
/// Limitations (kept simple on purpose): deletions and un-pins don't propagate —
/// sync only ever adds. Clearing history on one Mac won't clear the other.
final class SyncManager {

    private let store: ClipboardStore
    private var timer: Timer?

    /// Modification date of each foreign device file the last time we merged it,
    /// so quiet files cost nothing to check.
    private var lastMerged: [String: Date] = [:]

    /// A stable random identity for this Mac, minted on first use.
    static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "syncDeviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "syncDeviceID")
        return id
    }

    init(store: ClipboardStore) {
        self.store = store
    }

    // MARK: - Settings (read live, so toggling in Settings applies immediately)

    private var folderURL: URL? {
        guard UserDefaults.standard.bool(forKey: "syncEnabled"),
              let path = UserDefaults.standard.string(forKey: "syncFolderPath"),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private var devicesFolder: URL? { folderURL?.appendingPathComponent("devices", isDirectory: true) }
    private var imagesFolder: URL? { folderURL?.appendingPathComponent("images", isDirectory: true) }

    // MARK: - Lifecycle

    func start() {
        // Push whenever the store saves (new copy, pin, delete…).
        store.onDidSave = { [weak self] in self?.push() }

        // Pull on a slow poll. Same pattern as ClipboardMonitor: comparing file
        // dates is cheap, and `.common` mode keeps it alive while menus are open.
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        tick()
    }

    private func tick() {
        guard let devices = devicesFolder else { return }
        // First run against this folder: make sure our own file exists.
        let ownFile = devices.appendingPathComponent("\(Self.deviceID).json")
        if !FileManager.default.fileExists(atPath: ownFile.path) { push() }
        pull()
    }

    // MARK: - Push (write our history into the shared folder)

    private func push() {
        guard let devices = devicesFolder, let images = imagesFolder else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: devices, withIntermediateDirectories: true)
        try? fm.createDirectory(at: images, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(store.items) else { return }
        try? data.write(to: devices.appendingPathComponent("\(Self.deviceID).json"),
                        options: .atomic)

        // Upload image files the other Macs will need. Names are UUIDs, so a
        // file that already exists is the same content — skip it.
        for item in store.items {
            guard let source = store.imageURL(for: item) else { continue }
            let destination = images.appendingPathComponent(source.lastPathComponent)
            if !fm.fileExists(atPath: destination.path) {
                try? fm.copyItem(at: source, to: destination)
            }
        }
    }

    // MARK: - Pull (merge every other Mac's history into ours)

    private func pull() {
        guard let devices = devicesFolder, let images = imagesFolder else { return }
        let fm = FileManager.default
        let ownName = "\(Self.deviceID).json"

        let files = (try? fm.contentsOfDirectory(at: devices,
                                                 includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []

        for file in files where file.pathExtension == "json" && file.lastPathComponent != ownName {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if let seen = lastMerged[file.lastPathComponent], seen >= modified { continue }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: file),
                  let external = try? decoder.decode([ClipItem].self, from: data) else { continue }

            lastMerged[file.lastPathComponent] = modified
            store.merge(external: external, imagesFrom: images)
        }
    }
}
