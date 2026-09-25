import AppKit
import Carbon.HIToolbox

/// 'TbIs': marks our hotkeys in Carbon events.
private let hotkeySignature: OSType = 0x5462_4973

/// Global ⌃⌥ shortcuts through Carbon's RegisterEventHotKey, which (unlike an event tap)
/// needs no Accessibility permission and costs nothing until a shortcut is pressed.
@MainActor
final class HotkeyCenter {
    struct Binding {
        let keyCode: Int
        let action: @MainActor () -> Void
    }

    static let shared = HotkeyCenter()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var handler: EventHandlerRef?
    private(set) var isEnabled = false
    /// Keys another app had already registered with ⌃⌥.
    private(set) var unavailable: Set<Int> = []

    /// ⌃⌥ + each binding's key. Replaces whatever was registered before.
    func enable(_ bindings: [Binding]) {
        disable()
        installHandlerIfNeeded()
        let modifiers = UInt32(controlKey | optionKey)
        for (index, binding) in bindings.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(binding.keyCode), modifiers,
                                             EventHotKeyID(signature: hotkeySignature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id] = binding.action
            } else {
                unavailable.insert(binding.keyCode)
                NSLog("tabby island: ⌃⌥ key %d is taken by another app (%d)", binding.keyCode, status)
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

/// The island's shortcuts, for the status menu and the README.
enum Shortcut {
    static let toggle = kVK_Space
    static let next = kVK_ANSI_N
    static let tile = kVK_ANSI_G
    static let mode = kVK_ANSI_M
    static let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                         kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
}
