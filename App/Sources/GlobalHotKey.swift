import Carbon
import os

/// Wraps Carbon's `RegisterEventHotKey` to provide an OS-wide keyboard
/// shortcut that fires a Swift callback. The hotkey works even when the
/// app is not focused and **consumes** the keystroke so other apps don't
/// see it.
///
/// Lives in the App target (Apple glue / composition root) because Carbon
/// APIs are not available in pure SPM packages and cannot be unit-tested
/// via `swift test`.
///
/// **Ownership:** `register()` inserts `self` into a static map so the
/// Carbon C callback can route events. This is a **strong** reference --
/// the instance will not deallocate until `unregister()` removes it.
/// Always call `unregister()` before dropping the last external
/// reference, or the instance (and its Carbon resources) will leak.
///
/// Usage:
/// ```swift
/// let hotKey = GlobalHotKey(
///     keyCode: UInt32(kVK_ANSI_R),
///     modifiers: UInt32(cmdKey | shiftKey)
/// ) {
///     // handle hotkey press
/// }
/// hotKey.register()   // starts listening
/// hotKey.unregister() // stops listening (MUST call before dropping)
/// ```
@MainActor
final class GlobalHotKey {
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let handler: @MainActor () -> Void

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    /// Monotonic counter to generate unique hotkey IDs across instances.
    /// Wrapping addition is used; in practice 2^32 registrations will
    /// never be reached in a single app session.
    private static var nextID: UInt32 = 1

    /// Maps hotkey IDs back to their owning `GlobalHotKey` instance so the
    /// Carbon C callback can route events. `@MainActor`-isolated (inherited
    /// from the class) so the compiler enforces that all access happens on
    /// the main actor. The Carbon callback runs on the main thread and uses
    /// `MainActor.assumeIsolated` to satisfy the type system.
    ///
    /// **Retains a strong reference** to each registered instance. See the
    /// class-level ownership note.
    fileprivate static var activeHotKeys: [UInt32: GlobalHotKey] = [:]

    private var hotKeyID: UInt32 = 0

    private let logger = Logger(
        subsystem: "net.scosman.biscotti",
        category: "GlobalHotKey"
    )

    /// - Parameters:
    ///   - keyCode: The virtual key code (e.g. `kVK_ANSI_R`).
    ///   - modifiers: Carbon modifier mask (e.g. `cmdKey | shiftKey`).
    ///   - handler: Called on the main actor when the hotkey fires.
    init(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping @MainActor () -> Void
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler
    }

    /// Registers the hotkey with the system. Idempotent — calling while
    /// already registered is a no-op.
    func register() {
        guard hotKeyRef == nil else { return }

        // Assign a unique ID for this registration.
        hotKeyID = Self.nextID
        Self.nextID &+= 1
        Self.activeHotKeys[hotKeyID] = self

        // Install the Carbon event handler (once per registration).
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyCallback,
            1,
            &eventType,
            nil, // no user-data pointer needed; we use the static map
            &eventHandlerRef
        )
        if status != noErr {
            logger.error("InstallEventHandler failed: \(status)")
            Self.activeHotKeys.removeValue(forKey: hotKeyID)
            return
        }

        // Register the hotkey itself.
        let hotKeyIDStruct = EventHotKeyID(
            signature: OSType(0x4253_4354), // 'BSCT' — Biscotti
            id: hotKeyID
        )
        let regStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyIDStruct,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if regStatus != noErr {
            logger.error("RegisterEventHotKey failed: \(regStatus)")
            // Clean up the handler we just installed.
            if let ref = eventHandlerRef {
                RemoveEventHandler(ref)
                eventHandlerRef = nil
            }
            Self.activeHotKeys.removeValue(forKey: hotKeyID)
        }
    }

    /// Unregisters the hotkey and removes `self` from the static instance
    /// map. Idempotent — calling while not registered is a no-op.
    ///
    /// **Must be called before dropping the last external reference.**
    /// The static `activeHotKeys` map holds a strong reference to
    /// registered instances, so without `unregister()` the instance (and
    /// its Carbon resources) will never deallocate.
    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
        Self.activeHotKeys.removeValue(forKey: hotKeyID)
    }

    /// Called from the C callback when this instance's hotkey fires.
    fileprivate func fire() {
        handler()
    }
}

// MARK: - Carbon callback

/// Top-level C-compatible callback for Carbon hotkey events. Looks up the
/// `GlobalHotKey` instance via the event's hotkey ID and calls `fire()`.
private func carbonHotKeyCallback(
    _: EventHandlerCallRef?,
    event: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    // The Carbon callback runs on the main thread. Use assumeIsolated so
    // the compiler verifies all @MainActor access (including the static
    // activeHotKeys map lookup) is properly isolated.
    var handled = false
    MainActor.assumeIsolated {
        guard let hotKey = GlobalHotKey.activeHotKeys[hotKeyID.id] else {
            return
        }
        hotKey.fire()
        handled = true
    }

    return handled ? noErr : OSStatus(eventNotHandledErr)
}
