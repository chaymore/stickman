import Testing
import AppKit
@testable import Stickman

@Suite(.serialized)
struct CompanionModeTests {
    @Test func sparringCanOnlyBeginThroughTripleClickEntryPoint() {
        let controller = StickmanModeController.shared
        controller.setMode(.peaceful, reason: "test reset")

        #expect(!controller.setMode(.sparring, reason: "hover"))
        #expect(!controller.setMode(.sparring, reason: "spoken challenge"))
        #expect(controller.mode == .peaceful)

        controller.beginSparringFromTripleClick()
        #expect(controller.mode == .sparring)

        controller.setMode(.peaceful, reason: "test cleanup")
    }

    @Test func optionFToggleCanEndButNotBeginSparring() {
        let controller = StickmanModeController.shared
        controller.setMode(.peaceful, reason: "test reset")

        controller.toggle(reason: "Option-F")
        #expect(controller.mode == .peaceful)

        controller.beginSparringFromTripleClick()
        controller.toggle(reason: "Option-F")
        #expect(controller.mode == .peaceful)
    }

    @Test func voiceShortcutRequiresControlAndOptionTogether() {
        #expect(HotKeyManager.isVoiceShortcut(flags: [.control, .option]))
        #expect(!HotKeyManager.isVoiceShortcut(flags: [.control]))
        #expect(!HotKeyManager.isVoiceShortcut(flags: [.option]))
        #expect(!HotKeyManager.isVoiceShortcut(flags: [.control, .option, .command]))
        #expect(!HotKeyManager.isVoiceShortcut(flags: [.control, .option, .shift]))
    }

    @Test func voiceChordFiresOnACleanTapOnly() {
        var tracker = VoiceChordTracker()
        func step(_ flags: NSEvent.ModifierFlags, _ time: TimeInterval) -> Bool { tracker.flagsChanged(flags, at: time) }

        let clean = [step([.control], 0), step([.control, .option], 0.05), step([.option], 0.2), step([], 0.25)]
        #expect(clean == [false, false, false, true])

        // Control+Option+Arrow is someone else's shortcut.
        _ = step([.control, .option], 1)
        tracker.spoil()
        #expect(!step([], 1.2))

        // Held too long.
        _ = step([.control, .option], 2)
        #expect(!step([], 4))
    }
}
