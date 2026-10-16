import Foundation
import Carbon
import AppKit
import os
import Observation

/// Manages global system-wide hotkeys for Hopwatch using the Carbon Event Manager.
///
/// ── Why Carbon `RegisterEventHotKey` ──────────────────────────────────
/// On macOS, global hotkeys can be intercepted either via:
/// 1. `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`: Requires Accessibility permissions
///    (`AXIsProcessTrusted()`), and does NOT intercept events before other apps consume them.
/// 2. Carbon `RegisterEventHotKey`: Works without Accessibility permissions, intercepts the key
///    even when the application is unfocused or backgrounded (menu-bar only / LSUIElement),
///    and does not leak keystrokes.
///
/// This manager registers the hotkey with Carbon, routes events to an isolated handler,
/// and safely executes callbacks on `@MainActor`.
@MainActor
@Observable
public final class GlobalHotkeyManager {

    /// Shared singleton instance for convenient application-wide access.
    public static let shared = GlobalHotkeyManager()

    /// Default hotkey keycode: 'N' (ANSI key code 45).
    nonisolated public static let defaultKeyCode: UInt32 = 45

    /// Alternative hotkey keycode: 'H' (ANSI key code 4).
    nonisolated public static let alternativeKeyCode: UInt32 = 4

    /// Default modifier flags: Command + Option (`cmdKey | optionKey`).
    nonisolated public static let defaultModifiers: UInt32 = UInt32(cmdKey | optionKey)

    /// Four-character signature identifying Hopwatch hotkeys in the Carbon Event Manager ('HPWT').
    nonisolated public static let signature: OSType = 0x48505754

    /// Next unique identifier for registered hotkey instances.
    private static var nextId: UInt32 = 1

    /// Internal logger for hotkey lifecycle events.
    private let log = Logger(subsystem: "com.godigi.hopwatch", category: "hotkey")

    /// Virtual key code for the shortcut (e.g. 45 for 'N', 4 for 'H').
    public var keyCode: UInt32 {
        didSet {
            guard keyCode != oldValue else { return }
            if isEnabled {
                reRegister()
            }
        }
    }

    /// Carbon modifier flags (e.g. `cmdKey | optionKey`).
    public var modifiers: UInt32 {
        didSet {
            guard modifiers != oldValue else { return }
            if isEnabled {
                reRegister()
            }
        }
    }

    /// Callback invoked on `@MainActor` when the hotkey is triggered.
    public var onHotkeyPressed: (@MainActor () -> Void)?

    /// Whether the global hotkey is actively registered and listening.
    /// Setting this to `true` registers the hotkey; setting to `false` unregisters it.
    public var isEnabled: Bool = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                if !isRegistered {
                    let success = register()
                    if !success {
                        isEnabled = false
                    }
                }
            } else {
                if isRegistered {
                    unregister()
                }
            }
        }
    }

    /// Whether the Carbon hotkey is currently registered with the OS.
    public var isRegistered: Bool {
        hotKeyRef != nil
    }

    /// The Carbon event hotkey reference returned by `RegisterEventHotKey`.
    private var hotKeyRef: EventHotKeyRef?

    /// The Carbon event handler reference returned by `InstallEventHandler`.
    private var eventHandlerRef: EventHandlerRef?

    /// Pointer to the retained `RegistrationContext` bridging Carbon C callbacks to Swift.
    private var contextPointer: UnsafeMutableRawPointer?

    /// Unique identifier assigned to this manager's registration.
    private(set) var currentIdentifier: UInt32?

    /// Initializes a global hotkey manager with the specified keycode and modifiers.
    /// - Parameters:
    ///   - keyCode: The virtual key code (defaults to 45, 'N').
    ///   - modifiers: The Carbon modifiers (defaults to `cmdKey | optionKey`).
    ///   - onHotkeyPressed: Optional callback invoked when the hotkey is pressed.
    public init(
        keyCode: UInt32 = GlobalHotkeyManager.defaultKeyCode,
        modifiers: UInt32 = GlobalHotkeyManager.defaultModifiers,
        onHotkeyPressed: (@MainActor () -> Void)? = nil
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.onHotkeyPressed = onHotkeyPressed
    }

    isolated deinit {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
        }
        if let ptr = contextPointer {
            Unmanaged<RegistrationContext>.fromOpaque(ptr).release()
        }
    }

    /// Registers the global hotkey with the macOS Carbon subsystem.
    /// - Returns: `true` if registration succeeded or was already registered, `false` otherwise.
    @discardableResult
    public func register() -> Bool {
        guard !isRegistered else {
            isEnabled = true
            return true
        }

        let id = GlobalHotkeyManager.nextIdentifier()
        currentIdentifier = id

        let context = RegistrationContext(id: id, manager: self)
        let ptr = Unmanaged.passRetained(context).toOpaque()
        contextPointer = ptr

        let handler: EventHandlerProcPtr = { _, eventRef, userData in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let ctx = Unmanaged<RegistrationContext>.fromOpaque(userData).takeUnretainedValue()

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.id == ctx.id else {
                return OSStatus(eventNotHandledErr)
            }

            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    ctx.manager?.handleHotKey()
                }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        ctx.manager?.handleHotKey()
                    }
                }
            }
            return noErr
        }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        var installedHandler: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &spec,
            ptr,
            &installedHandler
        )

        guard installStatus == noErr, let installed = installedHandler else {
            log.error("Failed to install Carbon event handler (status: \(installStatus))")
            Unmanaged<RegistrationContext>.fromOpaque(ptr).release()
            contextPointer = nil
            currentIdentifier = nil
            return false
        }
        eventHandlerRef = installed

        let hotKeyID = EventHotKeyID(signature: GlobalHotkeyManager.signature, id: id)
        var registeredHotKey: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )

        guard regStatus == noErr, let registered = registeredHotKey else {
            log.error("Failed to register Carbon event hotkey (status: \(regStatus))")
            RemoveEventHandler(installed)
            eventHandlerRef = nil
            Unmanaged<RegistrationContext>.fromOpaque(ptr).release()
            contextPointer = nil
            currentIdentifier = nil
            return false
        }

        hotKeyRef = registered
        isEnabled = true
        log.info("Global hotkey registered successfully (id: \(id), shortcut: \(self.shortcutDisplayString))")
        return true
    }

    /// Unregisters the global hotkey from the macOS Carbon subsystem.
    public func unregister() {
        guard isRegistered else {
            isEnabled = false
            return
        }

        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }

        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }

        if let ptr = contextPointer {
            Unmanaged<RegistrationContext>.fromOpaque(ptr).release()
            contextPointer = nil
        }

        currentIdentifier = nil
        isEnabled = false
        log.info("Global hotkey unregistered")
    }

    /// Triggers the registered hotkey action manually.
    /// Useful for testing, menu items, or programmatic toggle paths.
    public func trigger() {
        handleHotKey()
    }

    /// Human-readable shortcut string (e.g. `⌥⌘N`, `⌥⌘H`).
    public var shortcutDisplayString: String {
        var parts: [String] = []
        if (modifiers & UInt32(controlKey)) != 0 {
            parts.append("⌃")
        }
        if (modifiers & UInt32(optionKey)) != 0 {
            parts.append("⌥")
        }
        if (modifiers & UInt32(shiftKey)) != 0 {
            parts.append("⇧")
        }
        if (modifiers & UInt32(cmdKey)) != 0 {
            parts.append("⌘")
        }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    // MARK: - Private Helpers

    private func reRegister() {
        unregister()
        _ = register()
    }

    private func handleHotKey() {
        log.info("Global hotkey pressed (\(self.shortcutDisplayString)), invoking action")
        onHotkeyPressed?()
    }

    private static func nextIdentifier() -> UInt32 {
        defer { nextId &+= 1 }
        return nextId
    }

    private static func keyName(for keyCode: UInt32) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        case 49: return "Space"
        default: return "Key(\(keyCode))"
        }
    }

    #if DEBUG
    /// Dispatches a synthetic Carbon event to verify the event handler pipeline in unit tests.
    @discardableResult
    func dispatchSyntheticCarbonEvent() -> Bool {
        guard let id = currentIdentifier else { return false }
        var eventRef: EventRef?
        let createStatus = CreateEvent(
            nil,
            OSType(kEventClassKeyboard),
            UInt32(kEventHotKeyPressed),
            GetCurrentEventTime(),
            OptionBits(kEventAttributeUserEvent),
            &eventRef
        )
        guard createStatus == noErr, let ev = eventRef else { return false }
        defer { ReleaseEvent(ev) }

        var hotKeyID = EventHotKeyID(signature: GlobalHotkeyManager.signature, id: id)
        let paramStatus = SetEventParameter(
            ev,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size,
            &hotKeyID
        )
        guard paramStatus == noErr else { return false }

        let sendStatus = SendEventToEventTarget(ev, GetApplicationEventTarget())
        return sendStatus == noErr
    }
    #endif
}

/// Thread-safe context object holding a weak reference to the manager and registration ID.
/// Passed through Carbon's `userData` raw pointer and retained/released with the hotkey registration.
private final class RegistrationContext: @unchecked Sendable {
    let id: UInt32
    weak var manager: GlobalHotkeyManager?

    init(id: UInt32, manager: GlobalHotkeyManager) {
        self.id = id
        self.manager = manager
    }
}
