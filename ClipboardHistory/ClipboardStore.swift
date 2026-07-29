import AppKit
import CryptoKit
import Foundation
import Vision

/// The single source of truth for the history.
///
/// `ObservableObject` + `@Published` is SwiftUI's change-notification system:
/// whenever `items` changes, every view observing this object redraws itself.
/// You never call "reload the table" by hand.
final class ClipboardStore: ObservableObject {

    @Published private(set) var items: [ClipItem] = []

    /// Called after every successful save. `SyncManager` uses this to mirror
    /// the history into the shared sync folder.
    var onDidSave: (() -> Void)?

    /// How many *unpinned* items we keep. Pinned ones are always kept.
    var maxItems: Int {
        let stored = UserDefaults.standard.integer(forKey: "maxItems")
        return stored == 0 ? 200 : stored   // `integer(forKey:)` returns 0 if never set
    }

    // MARK: - Where things live on disk

    private let folder: URL
    private let imagesFolder: URL
    private let fileURL: URL

    /// Keeps recently-shown images in memory so scrolling the list isn't
    /// hitting the disk on every frame.
    private let imageCache = NSCache<NSString, NSImage>()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
        folder = appSupport.appendingPathComponent("ClipboardHistory", isDirectory: true)
        imagesFolder = folder.appendingPathComponent("images", isDirectory: true)
        fileURL = folder.appendingPathComponent("history.json")

        // `try?` means "attempt this; if it throws, ignore it and carry on".
        try? FileManager.default.createDirectory(at: imagesFolder,
                                                 withIntermediateDirectories: true)
        load()
    }

    // MARK: - Adding

    func addText(_ text: String, rtf: Data? = nil,
                 source: NSRunningApplication?, concealedSource: Bool = false) {
        // Very long clippings get truncated so the JSON file stays sane.
        let capped = text.count > 200_000 ? String(text.prefix(200_000)) : text

        let item = ClipItem(id: UUID(),
                            kind: .text,
                            text: capped,
                            rtfData: rtf,
                            imageFileName: nil,
                            createdAt: Date(),
                            pinned: false,
                            isSensitive: concealedSource || Self.looksLikeSecret(capped),
                            sourceAppName: source?.localizedName,
                            sourceBundleID: source?.bundleIdentifier,
                            contentHash: Self.hash(Data(capped.utf8)))
        insert(item)
    }

    /// Heuristic for "this is probably a password or API key": known key
    /// prefixes, or a single dense token mixing letter cases, digits and
    /// symbols. Deliberately conservative — flagging a filename would
    /// auto-delete something harmless.
    static func looksLikeSecret(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" "), !t.contains("\n"), t.count <= 128 else { return false }

        let keyPrefixes = ["sk-", "sk_", "pk_", "rk_", "ghp_", "gho_", "github_pat_",
                           "AKIA", "xoxb-", "xoxp-", "AIza", "ya29.", "eyJhbGciOi"]
        if keyPrefixes.contains(where: { t.hasPrefix($0) }) { return true }

        // Not a URL, email or path — those share a password's shape. The email
        // test wants the full name@domain.tld form; a mere "@" inside a dense
        // token is more likely part of a password.
        let emailPattern = #"^[\w.+-]+@[\w-]+\.[\w.-]+$"#
        guard t.count >= 12,
              !t.hasPrefix("http"),
              t.range(of: emailPattern, options: .regularExpression) == nil,
              !t.hasPrefix("/"), !t.hasPrefix("~") else { return false }

        var classes = 0
        if t.rangeOfCharacter(from: .uppercaseLetters) != nil { classes += 1 }
        if t.rangeOfCharacter(from: .lowercaseLetters) != nil { classes += 1 }
        if t.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil { classes += 1 }
        // Digits are required: filenames and words rarely have them, passwords do.
        guard t.rangeOfCharacter(from: .decimalDigits) != nil else { return false }
        return classes >= 3
    }

    /// Remove sensitive items older than the user's auto-delete window.
    /// Called on a timer and at launch. Pinned items are never removed.
    func purgeExpiredSecrets() {
        let minutes = UserDefaults.standard.object(forKey: "secretAutoDeleteMinutes") as? Int ?? 15
        guard minutes > 0 else { return }
        let cutoff = Date().addingTimeInterval(TimeInterval(-minutes * 60))

        let expired = items.filter {
            $0.isSensitive == true && !$0.pinned && $0.createdAt < cutoff
        }
        guard !expired.isEmpty else { return }

        let expiredIDs = Set(expired.map { $0.id })
        for item in expired {
            if let file = item.imageFileName { deleteImageFile(file) }
        }
        items.removeAll { expiredIDs.contains($0.id) }
        save()
    }

    func addImage(_ image: NSImage, source: NSRunningApplication?) {
        guard let png = image.pngData() else { return }
        let hash = Self.hash(png)
        let fileName = "\(UUID().uuidString).png"

        do {
            try png.write(to: imagesFolder.appendingPathComponent(fileName))
        } catch {
            NSLog("ClipboardHistory: could not save image — \(error)")
            return
        }

        let item = ClipItem(id: UUID(),
                            kind: .image,
                            text: nil,
                            imageFileName: fileName,
                            createdAt: Date(),
                            pinned: false,
                            sourceAppName: source?.localizedName,
                            sourceBundleID: source?.bundleIdentifier,
                            contentHash: hash)
        insert(item)
        recognizeText(in: png, itemID: item.id)
    }

    /// Recognise text in any image that doesn't have it yet — items captured
    /// by versions of the app from before OCR existed. Called at launch.
    func backfillOCR() {
        for item in items where item.kind == .image && (item.ocrText ?? "").isEmpty {
            guard let url = imageURL(for: item),
                  let data = try? Data(contentsOf: url) else { continue }
            recognizeText(in: data, itemID: item.id)
        }
    }

    /// On-device OCR (Vision) so screenshots become searchable. Runs off the
    /// main thread; the result is attached to the item whenever it's ready.
    private func recognizeText(in pngData: Data, itemID: UUID) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let cgImage = NSImage(data: pngData)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                let text = lines.joined(separator: "\n")
                guard !text.isEmpty else { return }
                DispatchQueue.main.async {
                    guard let self,
                          let index = self.items.firstIndex(where: { $0.id == itemID })
                    else { return }
                    self.items[index].ocrText = text
                    self.save()
                }
            }
            request.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        }
    }

    private func insert(_ item: ClipItem) {
        if let index = items.firstIndex(where: { $0.contentHash == item.contentHash }) {
            // Already seen this exact content: bump it to the top instead of duplicating.
            var existing = items.remove(at: index)
            existing.createdAt = Date()
            // Same plain text, but this copy may have brought formatting along.
            if existing.rtfData == nil { existing.rtfData = item.rtfData }
            items.insert(existing, at: 0)

            // We may have just written a PNG we no longer need.
            if let newFile = item.imageFileName, newFile != existing.imageFileName {
                deleteImageFile(newFile)
            }
            // Re-copying an image that predates OCR: recognise it now.
            if existing.kind == .image, (existing.ocrText ?? "").isEmpty {
                backfillOCR()
            }
        } else {
            items.insert(item, at: 0)
        }
        trim()
        save()
    }

    // MARK: - Editing

    func togglePin(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle()
        // New pins go to the end of the pinned section; unpinning clears the slot.
        items[index].pinnedOrder = items[index].pinned
            ? (items.compactMap { $0.pinnedOrder }.max() ?? -1) + 1
            : nil
        save()
    }

    /// The pinned items in the order the list shows them.
    var pinnedInOrder: [ClipItem] {
        items.filter { $0.pinned }.sorted {
            let a = $0.pinnedOrder ?? Int.max, b = $1.pinnedOrder ?? Int.max
            return a != b ? a < b : $0.createdAt > $1.createdAt
        }
    }

    /// Drag-to-reorder: move one pinned item so it sits before another.
    func movePinned(_ draggedID: UUID, before targetID: UUID) {
        var pinnedItems = pinnedInOrder
        guard draggedID != targetID,
              let from = pinnedItems.firstIndex(where: { $0.id == draggedID })
        else { return }
        let moved = pinnedItems.remove(at: from)
        guard let to = pinnedItems.firstIndex(where: { $0.id == targetID }) else { return }
        pinnedItems.insert(moved, at: to)

        // Renumber 0…n; the list sorts by this.
        for (order, pinnedItem) in pinnedItems.enumerated() {
            if let index = items.firstIndex(where: { $0.id == pinnedItem.id }) {
                items[index].pinnedOrder = order
            }
        }
        save()
    }

    func delete(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let removed = items.remove(at: index)
        if let file = removed.imageFileName { deleteImageFile(file) }
        save()
    }

    func clearAll(keepPinned: Bool = true) {
        let survivors = keepPinned ? items.filter { $0.pinned } : []
        let survivorIDs = Set(survivors.map { $0.id })
        for item in items where !survivorIDs.contains(item.id) {
            if let file = item.imageFileName { deleteImageFile(file) }
        }
        items = survivors
        save()
    }

    /// Drop the oldest unpinned items once we're over the limit.
    private func trim() {
        var unpinnedKept = 0
        var kept: [ClipItem] = []
        for item in items {
            if item.pinned {
                kept.append(item)
            } else if unpinnedKept < maxItems {
                kept.append(item)
                unpinnedKept += 1
            } else if let file = item.imageFileName {
                deleteImageFile(file)
            }
        }
        items = kept
    }

    // MARK: - Sync

    /// Fold another Mac's history into ours. Content hash is the identity:
    /// new hashes are inserted, known hashes may pick up a newer date or a pin.
    /// Image files are copied out of the sync folder before their item is
    /// accepted, so we never show an entry whose PNG hasn't arrived yet.
    func merge(external: [ClipItem], imagesFrom externalImages: URL) {
        var changed = false

        for incoming in external {
            if let index = items.firstIndex(where: { $0.contentHash == incoming.contentHash }) {
                if incoming.createdAt > items[index].createdAt {
                    items[index].createdAt = incoming.createdAt
                    changed = true
                }
                if incoming.pinned && !items[index].pinned {
                    items[index].pinned = true
                    changed = true
                }
            } else {
                if incoming.kind == .image, let fileName = incoming.imageFileName {
                    let destination = imagesFolder.appendingPathComponent(fileName)
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        let source = externalImages.appendingPathComponent(fileName)
                        // iCloud may not have synced the PNG yet — skip the item
                        // for now; the next pull will pick it up.
                        guard (try? FileManager.default.copyItem(at: source, to: destination)) != nil
                        else { continue }
                    }
                }
                items.append(incoming)
                changed = true
            }
        }

        guard changed else { return }
        items.sort { $0.createdAt > $1.createdAt }
        trim()
        save()
    }

    // MARK: - Images

    /// Where an image item's PNG lives on disk (nil for text items).
    func imageURL(for item: ClipItem) -> URL? {
        guard let fileName = item.imageFileName else { return nil }
        return imagesFolder.appendingPathComponent(fileName)
    }

    func image(for item: ClipItem) -> NSImage? {
        guard let fileName = item.imageFileName else { return nil }
        if let cached = imageCache.object(forKey: fileName as NSString) { return cached }
        let url = imagesFolder.appendingPathComponent(fileName)
        guard let image = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: fileName as NSString)
        return image
    }

    private func deleteImageFile(_ fileName: String) {
        imageCache.removeObject(forKey: fileName as NSString)
        try? FileManager.default.removeItem(at: imagesFolder.appendingPathComponent(fileName))
    }

    // MARK: - Persistence

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        do {
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: .atomic)
            onDidSave?()
        } catch {
            NSLog("ClipboardHistory: could not save history — \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([ClipItem].self, from: data)) ?? []
    }

    // MARK: - Helpers

    /// SHA-256 of the content, hex-encoded. Only used to compare items.
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension NSImage {
    /// AppKit has no direct "give me PNG bytes", so we go through a bitmap rep.
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
