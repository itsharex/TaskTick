import AppKit
import Carbon.HIToolbox

/// Wraps Carbon's `RegisterEventHotKey` so the app can register a single global
/// hotkey and receive a callback when the user presses it system-wide.
///
/// Carbon over modern alternatives:
/// - `NSEvent.addGlobalMonitorForEvents` would also work but only fires when the
///   app is **not** focused; we want both. Plus it requires Accessibility
///   permission.
/// - Carbon's hotkey API is tiny, dependency-free, has no permission prompts,
///   and is the documented path Apple still recommends for a single shortcut.
@MainActor
final class GlobalHotkey {

    static let shared = GlobalHotkey()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var callback: (() -> Void)?
    /// 4-byte tag the OS includes in the event so we can disambiguate when more
    /// than one hotkey is registered. We only ever register one, so the value
    /// is arbitrary — pick something unique to our app to be safe.
    private let hotKeyID: UInt32 = 0x54_54_48_4B // 'TTHK'

    private init() {}

    /// Register or re-register the hotkey. Passing `nil` for keyCode unbinds.
    func register(keyCode: Int?, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        unregister()

        guard let keyCode else {
            callback = nil
            return
        }

        callback = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                       eventKind: UInt32(kEventHotKeyPressed))

        // Install a process-wide handler the first time we register. The handler
        // outlives subsequent re-registrations so we don't churn it.
        if handlerRef == nil {
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(),
                                hotKeyEventHandler,
                                1,
                                &eventType,
                                selfPtr,
                                &handlerRef)
        }

        let hotKeyID = EventHotKeyID(signature: self.hotKeyID, id: 1)
        RegisterEventHotKey(UInt32(keyCode),
                            carbonModifiers(from: modifiers),
                            hotKeyID,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    fileprivate func fire() {
        callback?()
    }

    /// Translate AppKit modifier flags into the Carbon modifier mask the
    /// hotkey API expects. `NSEvent.ModifierFlags` and Carbon's `cmdKey` etc.
    /// have completely different bit layouts — bridging requires an explicit
    /// mapping, not a bit-cast.
    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        return mods
    }
}

/// C function pointer the Carbon API expects. Must be a free function (or
/// `@convention(c)` closure with no captures), so it routes back into the
/// Swift class via the `userData` pointer we passed into `InstallEventHandler`.
private let hotKeyEventHandler: EventHandlerUPP = { _, _, userData in
    guard let userData else { return noErr }
    let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        hotkey.fire()
    }
    return noErr
}
