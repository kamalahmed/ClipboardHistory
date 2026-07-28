# How ClipboardHistory works

A guided tour of the code — written for readers who are new to Swift or macOS
development. The whole app is eleven small files.

## The big picture

```
ClipboardMonitor  →  ClipboardStore  →  HistoryView (inside an NSPanel)
     (watches)          (remembers)          (shows & pastes)
```

A timer watches the system clipboard. New content goes into a store that
saves everything to disk. A floating panel shows the list when you press the
hotkey. Three supporting pieces: a Carbon hotkey, a paste helper, and a sync
engine.

## File by file

| File | What it does |
|---|---|
| `ClipboardHistoryApp.swift` | The `@main` entry point. Hands everything to the app delegate. |
| `AppDelegate.swift` | Startup: menu bar icon, hotkey registration, first-launch behavior, the settings window. |
| `ClipItem.swift` | The data model for one clipboard entry, plus display helpers. |
| `ClipboardStore.swift` | Holds the list. Saves/loads JSON, de-duplicates, pins, trims, merges sync data. |
| `ClipboardMonitor.swift` | Polls the clipboard 2.5×/second and feeds new content to the store. |
| `GlobalHotKey.swift` | Registers the global shortcut via Carbon; defines the preset combos. |
| `PanelController.swift` | Shows/hides the floating popup and performs single- and multi-paste. |
| `HistoryView.swift` | The SwiftUI popup: search, list, multi-select, drag-and-drop, sharing. |
| `SettingsView.swift` | The settings window, including one-switch iCloud sync. |
| `Paster.swift` | Writes to the clipboard and synthesises the ⌘V keystroke. |
| `SyncManager.swift` | Mirrors history into a shared folder and merges other Macs' files. |

## Why it's built the way it is

**Polling, not notifications.** macOS has no "clipboard changed" event. Every
clipboard manager polls `NSPasteboard.changeCount` — an integer that
increments on each copy. Comparing an integer 2.5×/second is effectively free;
content is only read when the number moves.

**Plain text on purpose.** The monitor reads the pasteboard's plain-string
flavour, so all formatting (fonts, colors, HTML) is stripped at capture time.
That's why pasting from the app always produces clean text.

**An AppKit panel around a SwiftUI view.** SwiftUI still can't express "a
floating panel under the mouse that takes keyboard focus and vanishes on
click-away", so the window is an `NSPanel` whose contents are SwiftUI, glued
by `NSHostingView`.

**Carbon for the hotkey.** `RegisterEventHotKey` is ancient but it's the only
global-shortcut API that needs no Accessibility permission. Accessibility is
only requested for the optional auto-paste keystroke.

**Sync without a server.** Every Mac writes only its own file
(`devices/<id>.json`) inside the shared folder and merges everyone else's by
content hash. No file ever has two writers, so cloud services never see a
conflict. iCloud Drive (or Dropbox) does the transport; the app itself has no
networking code at all. "One switch" iCloud sync works because iCloud Drive
lives at the same path on every Mac
(`~/Library/Mobile Documents/com~apple~CloudDocs`).

**De-duplication by content hash.** Each entry stores a SHA-256 of its
content. Copying the same thing twice bumps the existing entry to the top;
the same trick makes sync merges idempotent.

## Swift concepts worth knowing, if the language is new to you

**`ObservableObject` / `@Published` / `@ObservedObject`.** SwiftUI's
change-tracking. `ClipboardStore.items` is `@Published`; any view observing
the store redraws automatically. There is no "reload the list" code anywhere.

**`@State` and `@FocusState`.** View-local memory that survives SwiftUI's
constant view rebuilding. `@FocusState` is the same idea for "where is the
keyboard cursor".

**`@AppStorage`.** A property wrapper over `UserDefaults`: read/write it like
a variable, it persists and triggers redraws.

**Optionals (`String?`, `if let`, `guard let`, `try?`).** "Might be missing"
is part of the type system. `guard let` unwraps or bails out early; `try?`
turns a throwing call into an optional.

**`[weak self]` in closures.** Breaks retain cycles between long-lived objects
(timers, callbacks) and the objects that own them.

## Known rough edges

- A copy can take up to 0.4s to appear (the polling interval).
- Password-manager filtering relies on apps marking their copies as concealed
  (the `org.nspasteboard.*` convention). Most do; not all.
- The history JSON is not encrypted — it's readable by anything running as
  your user.
- Sync only adds: deletions don't propagate between Macs.
- Accessibility permission must be re-granted after rebuilds, because ad-hoc
  code signatures change on every build.

## Roadmap

- **Direct Mac-to-Mac sync** over the local network (Bonjour discovery, no
  cloud at all) — needs a proper pairing/trust design and two machines to
  test against.
- **CloudKit sync** once the app is signed with a paid developer account:
  push-based, near-instant, zero-setup.
- **Multiple lists / boards** for organising snippets by project.
- **A free-form shortcut recorder** instead of preset combos.
- **Exclude apps** — never record from chosen apps.
- **Fuzzy search** instead of substring matching.
- **Clear-after-N-minutes** for anything that looks like a secret.
