import Darwin
import Foundation
import NightLockCore

guard geteuid() == 0 else {
    fputs("Run this recovery tool with sudo.\n", stderr)
    exit(1)
}

do {
    let partOne = try String(contentsOfFile: NightLockPaths.recoveryPartOne, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let partTwo = try String(contentsOfFile: NightLockPaths.recoveryPartTwo, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    print("NightLock emergency recovery requested.")
    print("This key can disable enforcement or change the protected schedule.")
    print("Waiting 30 seconds to make this a deliberate action...")
    sleep(30)
    print("\nRecovery key:\n\(partOne)\(partTwo)")
} catch {
    fputs("Could not recover the split key: \(error.localizedDescription)\n", stderr)
    exit(1)
}
