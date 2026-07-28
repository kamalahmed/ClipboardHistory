import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Everything to do with putting an item back on the clipboard, and optionally
/// pressing ⌘V for you.
///
/// `enum` with only static members is a common Swift idiom for a namespace —
/// unlike a `class` or `struct`, an empty enum can't be instantiated by mistake.
enum Paster {

    static func copyToPasteboard(_ item: ClipItem, store: ClipboardStore) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .text:
            // Plain text by default; the original formatting only when the
            // user turned "Always paste as plain text" off and we captured it.
            let plainOnly = UserDefaults.standard.object(forKey: "pastePlainText") as? Bool ?? true
            if !plainOnly, let rtf = item.rtfData {
                pasteboard.setData(rtf, forType: .rtf)
            }
            pasteboard.setString(item.text ?? "", forType: .string)
        case .image:
            if let image = store.image(for: item), let tiff = image.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        }
    }

    /// Synthesising keystrokes requires the Accessibility permission, which the
    /// user grants in System Settings. Without it, we just leave the content on
    /// the clipboard and let them press ⌘V themselves.
    static var canAutoPaste: Bool { AXIsProcessTrusted() }

    static func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Fake a ⌘V keypress into whatever app is frontmost right now.
    static func sendCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey = CGKeyCode(kVK_ANSI_V)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
