import AppKit
import Carbon.HIToolbox

/// 'TbIs': marks our hotkeys in Carbon events.
private let hotkeySignature: OSType = 0x5462_4973

/// Global shortcuts through Carbon's RegisterEventHotKey, which (unlike an event tap) needs no
/// Accessibility permission and costs nothing until a shortcut is pressed.
@MainActor
final class HotkeyCenter {
    struct Binding {
        let combo: KeyCombo
        let action: @MainActor () -> Void
    }

    static let shared = HotkeyCenter()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var handler: EventHandlerRef?
    private(set) var isEnabled = false
    /// Combos another app had already registered.
    private(set) var unavailable: Set<KeyCombo> = []

    /// Registers every binding. Replaces whatever was registered before.
    func enable(_ bindings: [Binding]) {
        disable()
        installHandlerIfNeeded()
        for (index, binding) in bindings.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(binding.combo.keyCode), binding.combo.modifiers.carbon,
                                             EventHotKeyID(signature: hotkeySignature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id] = binding.action
            } else {
                unavailable.insert(binding.combo)
                NSLog("tabby island: %@ is taken by another app (%d)", binding.combo.display, status)
            }
        }
        isEnabled = true
        Debug.log("hotkeys registered: \(refs.count) of \(bindings.count)")
    }

    func disable() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
        unavailable = []
        isEnabled = false
    }

    fileprivate func fire(_ id: UInt32) {
        Debug.log("hotkey \(id)")
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotkeyPressed, 1, &spec, nil, &handler)
    }
}

private func hotkeyPressed(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKey = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
    guard status == noErr, hotKey.signature == hotkeySignature else { return OSStatus(eventNotHandledErr) }
    let id = hotKey.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HotkeyCenter.shared.fire(id) }
    }
    return noErr
}
