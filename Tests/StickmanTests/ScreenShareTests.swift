import Testing
import AppKit
@testable import Stickman

@Suite
struct ScreenShareTests {
    private func run(_ debouncer: inout ScreenShareDebouncer, capturing: Bool, from start: TimeInterval, seconds: TimeInterval) -> [Bool] {
        var flips: [Bool] = []
        var now = start
        while now < start + seconds {
            if debouncer.update(rawCapturing: capturing, now: now) { flips.append(debouncer.isSharing) }
            now += 0.3
        }
        return flips
    }

    @Test func aQuickScreenshotDoesNotCountAsSharing() {
        var debouncer = ScreenShareDebouncer()
        #expect(run(&debouncer, capturing: true, from: 0, seconds: 0.5).isEmpty)
        #expect(run(&debouncer, capturing: false, from: 0.6, seconds: 3).isEmpty)
        #expect(!debouncer.isSharing)
    }

    @Test func sustainedCaptureStartsAndEndsSharing() {
        var debouncer = ScreenShareDebouncer()
        #expect(run(&debouncer, capturing: true, from: 0, seconds: 2) == [true])
        // A momentary gap in the stream keeps Stickman hidden.
        #expect(run(&debouncer, capturing: false, from: 2, seconds: 1).isEmpty)
        #expect(run(&debouncer, capturing: true, from: 3, seconds: 1).isEmpty)
        #expect(run(&debouncer, capturing: false, from: 4, seconds: 3) == [false])
    }

    @Test func stickmansOwnCaptureIsIgnored() {
        var debouncer = ScreenShareDebouncer()
        debouncer.ignoreCapture(until: 2.5)
        #expect(run(&debouncer, capturing: true, from: 0, seconds: 2.5).isEmpty)
        #expect(!debouncer.isSharing)
    }

    @Test func walkingNeedsOptionRightClick() {
        #expect(HotKeyManager.isWalkClick(flags: [.option]))
        #expect(HotKeyManager.isWalkClick(flags: [.option, .shift]))
        #expect(!HotKeyManager.isWalkClick(flags: []))
        #expect(!HotKeyManager.isWalkClick(flags: [.control]))
        #expect(!HotKeyManager.isWalkClick(flags: [.option, .command]))
    }
}
