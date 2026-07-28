import Foundation

/// What sort of thing we captured. Right now: plain text or an image.
/// `String` + `Codable` means Swift can save this straight into JSON.
enum ClipKind: String, Codable {
    case text
    case image
}

/// One entry in the clipboard history.
///
/// `Identifiable` lets SwiftUI lists tell rows apart (via `id`).
/// `Codable` lets us encode the whole array to a JSON file on disk.
struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: ClipKind

    /// Set when `kind == .text`.
    var text: String?

    /// The original rich-text bytes (RTF), kept alongside the plain text when
    /// the copy had formatting. Only used when the "keep formatting" setting
    /// is on; capped at capture time so the history file stays small.
    var rtfData: Data?

    /// Set when `kind == .image`. The image bytes live in a separate PNG file
    /// (JSON is a terrible place for megabytes of image data), and this is just
    /// the file name inside the app's `images` folder.
    var imageFileName: String?

    var createdAt: Date
    var pinned: Bool

    /// Manual position among pinned items (drag to reorder). Optional so old
    /// history files still decode; nil sorts after explicitly ordered items.
    var pinnedOrder: Int?

    /// Text recognised inside an image clipping (on-device OCR). Searchable,
    /// and copyable via the context menu.
    var ocrText: String?

    /// True when this looks like a password or API key — either the source
    /// app marked the copy as concealed, or the content matches secret
    /// patterns. Sensitive items get a key icon and can auto-delete.
    var isSensitive: Bool?

    /// Which app was frontmost when this was copied — nice context in the list.
    var sourceAppName: String?
    var sourceBundleID: String?

    /// A fingerprint of the content, used to spot "you copied this exact thing
    /// again" so we move the old entry to the top instead of adding a duplicate.
    var contentHash: String

    // MARK: - Display helpers
    //
    // `var x: T { ... }` with no `=` is a *computed property*: it isn't stored,
    // it's recalculated each time you read it. Handy for derived display values.

    /// The single line we show in the list.
    var previewText: String {
        switch kind {
        case .text:
            let raw = text ?? ""
            let collapsed = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ⏎ ")
            return collapsed.isEmpty ? "(empty)" : collapsed
        case .image:
            if let ocr = ocrText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " "),
               !ocr.isEmpty {
                return "Image · " + String(ocr.prefix(80))
            }
            return "Image"
        }
    }

    /// What the search box matches against. Images match their recognised text
    /// too, so a screenshot of an error message is findable by its words.
    var searchText: String {
        switch kind {
        case .text:  return text ?? ""
        case .image: return "image \(sourceAppName ?? "") \(ocrText ?? "")"
        }
    }

    /// True if the text looks like a URL — we show a different icon for those.
    var looksLikeURL: Bool {
        guard kind == .text, let text else { return false }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(" "), t.count < 2048 else { return false }
        return t.hasPrefix("http://") || t.hasPrefix("https://")
    }

    var iconName: String {
        if isSensitive == true { return "key.fill" }
        switch kind {
        case .image: return "photo"
        case .text:  return looksLikeURL ? "link" : "text.alignleft"
        }
    }

    /// Rough "how many characters / how big" label.
    var sizeLabel: String {
        switch kind {
        case .text:
            let n = (text ?? "").count
            return n == 1 ? "1 character" : "\(n) characters"
        case .image:
            return "image"
        }
    }
}
