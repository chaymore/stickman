import Carbon
import AppKit

final class HotKeyManager {
    private enum HotKey: UInt32 {
        case toggleVisibility = 1
        case openMenu = 4
    }

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var modifierMonitors: [Any] = []
    private var eventHandlerRef: EventHandlerRef?
    private var voiceChord = VoiceChordTracker()
    private let signature = OSType(0x4D494C4F)
    private let onToggle: () -> Void
    private let onOpenMenu: () -> Void
    private let onToggleVoice: () -> Void

    init(
        onToggle: @escaping () -> Void,
        onOpenMenu: @escaping () -> Void,
        onToggleVoice: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onOpenMenu = onOpenMenu
        self.onToggleVoice = onToggleVoice
    }

    func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData, let eventRef else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let result = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard result == noErr, hotKeyID.signature == manager.signature else { return noErr }
                manager.handle(id: hotKeyID.id)
                return noErr
            },
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )
        guard status == noErr else { return }

        register(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey), id: .toggleVisibility)
        register(keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(controlKey), id: .openMenu)
        installVoiceChordMonitors()
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: HotKey) {
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id.rawValue)
        if RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference) == noErr,
           let reference {
            hotKeyRefs.append(reference)
        }
    }

    private func handle(id: UInt32) {
        switch HotKey(rawValue: id) {
        case .toggleVisibility: onToggle()
        case .openMenu: onOpenMenu()
        case nil: break
        }
    }

    /// Control+Option toggles voice when tapped on its own: press both, let go, no other key.
    /// Firing on release keeps shortcuts like Control+Option+Arrow from starting voice.
    private func installVoiceChordMonitors() {
        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            if self.voiceChord.flagsChanged(event.modifierFlags, at: event.timestamp) { self.onToggleVoice() }
        }
        let spoilHandler: (NSEvent) -> Void = { [weak self] _ in self?.voiceChord.spoil() }
        let spoilers: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let monitors: [Any?] = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler),
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flagsHandler($0); return $0 },
            NSEvent.addGlobalMonitorForEvents(matching: spoilers, handler: spoilHandler),
            NSEvent.addLocalMonitorForEvents(matching: spoilers) { spoilHandler($0); return $0 }
        ]
        modifierMonitors = monitors.compactMap { $0 }
    }

    /// Option+click sends Stickman somewhere. The click still reaches the app under it.
    static func isWalkClick(flags: NSEvent.ModifierFlags) -> Bool {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.option)
            && !flags.contains(.command)
            && !flags.contains(.control)
    }

    static func isVoiceShortcut(flags: NSEvent.ModifierFlags) -> Bool {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.control)
            && flags.contains(.option)
            && !flags.contains(.command)
            && !flags.contains(.shift)
    }

    deinit {
        hotKeyRefs.forEach { _ = UnregisterEventHotKey($0) }
        modifierMonitors.forEach { NSEvent.removeMonitor($0) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}

/// Recognizes a Control+Option tap: both held together, then all modifiers released,
/// with no key, click, or scroll in between, inside a short window.
struct VoiceChordTracker {
    static let maximumHold: TimeInterval = 1.2
    private var chordStartedAt: TimeInterval?
    private var isSpoiled = false

    /// Returns true when this change completes a clean tap.
    mutating func flagsChanged(_ flags: NSEvent.ModifierFlags, at time: TimeInterval) -> Bool {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        if HotKeyManager.isVoiceShortcut(flags: flags) {
            if chordStartedAt == nil {
                chordStartedAt = time
                isSpoiled = false
            }
            return false
        }
        if flags.contains(.command) || flags.contains(.shift) { isSpoiled = true }
        guard flags.intersection([.control, .option, .command, .shift]).isEmpty else { return false }
        defer { chordStartedAt = nil; isSpoiled = false }
        guard let started = chordStartedAt, !isSpoiled else { return false }
        return time - started <= Self.maximumHold
    }

    mutating func spoil() {
        if chordStartedAt != nil { isSpoiled = true }
    }
}
