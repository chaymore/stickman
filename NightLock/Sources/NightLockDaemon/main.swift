import Darwin
import Foundation
import NightLockCore

private let beginMarker = "# BEGIN NIGHTLOCK MANAGED BLOCK"
private let endMarker = "# END NIGHTLOCK MANAGED BLOCK"

final class NightLockDaemon {
    private var lastRequestMessage: String?

    func run() -> Never {
        while true {
            autoreleasepool {
                do {
                    var config = try NightLockFiles.loadConfig()
                    processRequests(config: &config)
                    let active = config.enabled && config.schedule.isActive(at: Date())
                    let changed = try enforceHosts(config: config, active: active)
                    if changed { flushDNSCache() }
                    try writeStatus(config: config, active: active)
                } catch {
                    writeErrorStatus(error)
                }
            }
            sleep(2)
        }
    }

    private func processRequests(config: inout NightLockConfig) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(atPath: NightLockPaths.requests) else { return }

        for filename in files where filename.hasSuffix(".json") {
            let path = NightLockPaths.requests + "/" + filename
            defer { try? fileManager.removeItem(atPath: path) }

            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let request = try NightLockFiles.decoder.decode(ProtectedUpdateRequest.self, from: data)
                guard abs(request.createdAt.timeIntervalSinceNow) < 600 else {
                    lastRequestMessage = "Rejected an expired settings request."
                    continue
                }
                guard RecoveryKeyVerifier.verify(
                    key: request.recoveryKey,
                    salt: config.recoverySalt,
                    expectedHash: config.recoveryHash
                ) else {
                    lastRequestMessage = "Rejected settings change: recovery key was incorrect."
                    continue
                }
                guard valid(hour: request.startHour, minute: request.startMinute),
                      valid(hour: request.endHour, minute: request.endMinute)
                else {
                    lastRequestMessage = "Rejected settings change: schedule was invalid."
                    continue
                }

                config.enabled = request.enabled
                config.startHour = request.startHour
                config.startMinute = request.startMinute
                config.endHour = request.endHour
                config.endMinute = request.endMinute
                try writeJSON(config, to: NightLockPaths.config, permissions: 0o644)
                lastRequestMessage = "Protected settings updated successfully."
            } catch {
                lastRequestMessage = "Rejected malformed settings request."
            }
        }
    }

    private func valid(hour: Int, minute: Int) -> Bool {
        (0 ... 23).contains(hour) && (0 ... 59).contains(minute)
    }

    private func enforceHosts(config: NightLockConfig, active: Bool) throws -> Bool {
        let current = try String(contentsOfFile: NightLockPaths.hostsFile, encoding: .utf8)
        var lines = current.components(separatedBy: .newlines)
        var filtered: [String] = []
        var insideManagedBlock = false

        for line in lines {
            if line == beginMarker {
                insideManagedBlock = true
                continue
            }
            if line == endMarker {
                insideManagedBlock = false
                continue
            }
            if !insideManagedBlock { filtered.append(line) }
        }

        while filtered.last?.isEmpty == true { filtered.removeLast() }

        if active {
            filtered.append("")
            filtered.append(beginMarker)
            filtered.append("# Managed by NightLock. Protected schedule: \(config.schedule.displayText)")
            filtered.append("127.0.0.1 " + config.blockedHosts.joined(separator: " "))
            filtered.append("::1 " + config.blockedHosts.joined(separator: " "))
            filtered.append(endMarker)
        }

        lines = filtered
        let desired = lines.joined(separator: "\n") + "\n"
        guard desired != current else { return false }
        try overwriteFile(path: NightLockPaths.hostsFile, data: Data(desired.utf8))
        return true
    }

    private func overwriteFile(path: String, data: Data) throws {
        let descriptor = open(path, O_WRONLY | O_TRUNC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var total = 0
            while total < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: total), data.count - total)
                guard count > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                total += count
            }
        }
    }

    private func writeStatus(config: NightLockConfig, active: Bool) throws {
        let status = NightLockStatus(
            active: active,
            enabled: config.enabled,
            schedule: config.schedule.displayText,
            lastRequestMessage: lastRequestMessage
        )
        try writeJSON(status, to: NightLockPaths.status, permissions: 0o644)
    }

    private func writeErrorStatus(_ error: Error) {
        let status = NightLockStatus(
            active: false,
            enabled: true,
            schedule: "Unavailable",
            lastRequestMessage: "Daemon error: \(error.localizedDescription)"
        )
        try? writeJSON(status, to: NightLockPaths.status, permissions: 0o644)
    }

    private func writeJSON<T: Encodable>(_ value: T, to path: String, permissions: mode_t) throws {
        let data = try NightLockFiles.encoder.encode(value)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        chmod(path, permissions)
    }

    private func flushDNSCache() {
        run("/usr/bin/dscacheutil", arguments: ["-flushcache"])
        run("/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"])
    }

    private func run(_ executable: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }
}

guard geteuid() == 0 else {
    fputs("NightLockDaemon must run as root.\n", stderr)
    exit(1)
}

NightLockDaemon().run()
