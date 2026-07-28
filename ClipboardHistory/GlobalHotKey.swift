import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut that fires even when another app is in front.
///
/// This uses Carbon, which is an ancient C API — but `RegisterEventHotKey` is
/// still the only way to get a global shortcut *without* asking the user for
/// Accessibility permission, so every menu bar app on your Mac uses it too.
final class GlobalHotKey {

    // Carbon calls us back through a plain C function pointer, which cannot
    // capture Swift context. So we park the closures in a static dictionary
    // keyed by hot key id, and look them up inside the callback.
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?

    /// - Parameters:
    ///   - keyCode: a `kVK_…` constant, e.g. `kVK_ANSI_V`.
    ///   - modifiers: Carbon modifier mask, e.g. `cmdKey | shiftKey`.
    /// Returns `nil` (a *failable initialiser*) when the shortcut is already
    /// taken by another app.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        GlobalHotKey.installHandlerIfNeeded()

        id = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1
        GlobalHotKey.actions[id] = action

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C4950), id: id) // 'CLIP'
        let status = RegisterEventHotKey(keyCode,
                                         modifiers,
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &hotKeyRef)
        guard status == noErr else {
            GlobalHotKey.actions[id] = nil
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        GlobalHotKey.actions[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var pressedID = EventHotKeyID()
            let result = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &pressedID)
            if result == noErr, let action = GlobalHotKey.actions[pressedID.id] {
                DispatchQueue.main.async(execute: action)
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
