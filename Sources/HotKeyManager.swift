import Carbon
import AppKit

final class HotKeyManager {
    private enum HotKey: UInt32 {
        case toggleVisibility = 1
        case quickAssist = 2
        case toggleCombat = 3
        case openMenu = 4
    }

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var modifierMonitors: [Any] = []
    private var eventHandlerRef: EventHandlerRef?
    private var voiceChordLatched = false
    private let signature = OSType(0x4D494C4F)
    private let onToggle: () -> Void
    private let onQuickAssist: () -> Void
    private let onToggleCombat: () -> Void
    private let onOpenMenu: () -> Void
    private let onStartVoice: () -> Void

    init(
        onToggle: @escaping () -> Void,
        onQuickAssist: @escaping () -> Void,
        onToggleCombat: @escaping () -> Void,
        onOpenMenu: @escaping () -> Void,
        onStartVoice: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onQuickAssist = onQuickAssist
        self.onToggleCombat = onToggleCombat
        self.onOpenMenu = onOpenMenu
        self.onStartVoice = onStartVoice
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
        register(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), id: .quickAssist)
        register(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey), id: .toggleCombat)
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
        case .quickAssist: onQuickAssist()
        case .toggleCombat: onToggleCombat()
        case .openMenu: onOpenMenu()
        case nil: break
        }
    }

    private func installVoiceChordMonitors() {
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleModifierFlags(event.modifierFlags)
        }) {
            modifierMonitors.append(globalMonitor)
        }
        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleModifierFlags(event.modifierFlags)
            return event
        }) {
            modifierMonitors.append(localMonitor)
        }
    }

    private func handleModifierFlags(_ flags: NSEvent.ModifierFlags) {
        let isVoiceChord = Self.isVoiceShortcut(flags: flags)
        if isVoiceChord, !voiceChordLatched {
            voiceChordLatched = true
            onStartVoice()
        } else if !isVoiceChord {
            voiceChordLatched = false
        }
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
