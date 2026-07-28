import SwiftUI

/// The contents of the popup: a search field on top, a scrolling list below.
struct HistoryView: View {

    /// `@ObservedObject` means "watch this object and redraw when it changes".
    @ObservedObject var store: ClipboardStore

    var onPick: (ClipItem) -> Void
    var onPickMany: ([ClipItem]) -> Void
    var onClose: () -> Void
    var onOpenSettings: () -> Void

    /// `@State` is view-local memory that survives redraws.
    @State private var query = ""
    @State private var selectedID: UUID?

    /// ⌘-clicked items, for pasting several at once.
    @State private var multiSelectedIDs: Set<UUID> = []

    /// `@FocusState` lets us put the cursor in the search field programmatically.
    @FocusState private var searchFocused: Bool

    /// Pinned items first, then newest first. Recomputed on every redraw, which
    /// is fine at these list sizes.
    private var results: [ClipItem] {
        store.items
            .filter { query.isEmpty || $0.searchText.localizedCaseInsensitiveContains(query) }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                return a.createdAt > b.createdAt
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if results.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(minWidth: 380, minHeight: 360)
        .onAppear {
            searchFocused = true
            selectedID = results.first?.id
        }
    }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search clipboard history", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .onSubmit { pasteSelected() }
                .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
                .onKeyPress(.escape) { onClose(); return .handled }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        // Extra leading room so the window's red close button doesn't sit on
        // top of the magnifying-glass icon.
        .padding(.leading, 16)
        .padding(.vertical, 10)
        // Keep the highlight on a real row as the filter narrows.
        .onChange(of: query) { _, _ in
            if selectedID == nil || !results.contains(where: { $0.id == selectedID }) {
                selectedID = results.first?.id
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { item in
                        ClipRow(item: item,
                                store: store,
                                isSelected: item.id == selectedID,
                                isMultiSelected: multiSelectedIDs.contains(item.id))
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // ⌘-click builds a multi-selection instead of pasting.
                                if NSEvent.modifierFlags.contains(.command) {
                                    if multiSelectedIDs.contains(item.id) {
                                        multiSelectedIDs.remove(item.id)
                                    } else {
                                        multiSelectedIDs.insert(item.id)
                                    }
                                    selectedID = item.id
                                } else {
                                    selectedID = item.id
                                    onPick(item)
                                }
                            }
                            // Rows can be dragged straight into other apps:
                            // text drops as text, images drop as a PNG file.
                            .onDrag {
                                if item.kind == .image, let url = store.imageURL(for: item),
                                   let provider = NSItemProvider(contentsOf: url) {
                                    return provider
                                }
                                return NSItemProvider(object: (item.text ?? "") as NSString)
                            }
                            .contextMenu {
                                Button(item.pinned ? "Unpin" : "Pin") {
                                    store.togglePin(item)
                                }
                                if item.kind == .text {
                                    ShareLink(item: item.text ?? "") {
                                        Label("Share…", systemImage: "square.and.arrow.up")
                                    }
                                } else if let url = store.imageURL(for: item) {
                                    ShareLink(item: url) {
                                        Label("Share…", systemImage: "square.and.arrow.up")
                                    }
                                }
                                Button("Delete", role: .destructive) {
                                    store.delete(item)
                                }
                            }
                    }
                }
            }
            .onChange(of: selectedID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "Nothing copied yet" : "No matches")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("↑↓ select", systemImage: "arrow.up.arrow.down")
            Label("⏎ paste", systemImage: "return")
            Label("⌘click multi", systemImage: "command")
            Label("esc close", systemImage: "escape")
            Spacer()
            if multiSelectedIDs.count > 1 {
                Text("⏎ pastes \(multiSelectedIDs.count) items")
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("\(store.items.count) saved")
            }
        }
        .labelStyle(.titleOnly)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    // MARK: - Keyboard

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + delta, 0), results.count - 1)
        selectedID = results[next].id
    }

    private func pasteSelected() {
        // With a ⌘-click multi-selection, Return pastes all of them together
        // (in list order). Otherwise, the highlighted row as usual.
        if multiSelectedIDs.count > 1 {
            onPickMany(results.filter { multiSelectedIDs.contains($0.id) })
            return
        }
        guard let selectedID,
              let item = results.first(where: { $0.id == selectedID }) else { return }
        onPick(item)
    }
}

/// One row in the list. Kept `private` because nothing else needs it.
private struct ClipRow: View {

    let item: ClipItem
    @ObservedObject var store: ClipboardStore
    let isSelected: Bool
    let isMultiSelected: Bool

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isMultiSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
            } else {
                icon
                    .frame(width: 26, height: 26)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.previewText)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    if let app = item.sourceAppName {
                        Text(app)
                        Text("·")
                    }
                    Text(item.createdAt, format: .relative(presentation: .numeric))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            if item.pinned || hovering {
                Button { store.togglePin(item) } label: {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.plain)
                .foregroundStyle(item.pinned ? Color.accentColor : Color.secondary)
                .help(item.pinned ? "Unpin" : "Pin to the top")
            }

            if hovering {
                Button { store.delete(item) } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var icon: some View {
        if item.kind == .image, let image = store.image(for: item) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: item.iconName)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}
