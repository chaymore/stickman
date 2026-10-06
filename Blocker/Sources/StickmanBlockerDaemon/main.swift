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
                    let now = Date()
                    var ledger = loadLedger(at: now)
                    processRequests(config: &config, ledger: &ledger, now: now)
                    processAllowanceRequests(config: config, ledger: &ledger, now: now)
                    try writeJSON(ledger, to: NightLockPaths.allowanceLedger, permissions: 0o644)

                    let active = config.enabled && config.schedule.isActive(at: now)
                    let activeAllowances = openAllowanceDomains(config: config, ledger: ledger, now: now)
                    let changed = try enforceHosts(
                        config: config,
                        active: active,
                        activeAllowances: activeAllowances
                    )
                    if changed { flushDNSCache() }
                    try writeStatus(config: config, active: active, ledger: ledger)
                } catch {
                    writeErrorStatus(error)
                }
            }
            sleep(2)
        }
    }

    private func loadLedger(at date: Date) -> DailyAllowanceLedger {
        let today = NightLockFiles.dayKey(for: date)
        guard let existing = try? NightLockFiles.loadAllowanceLedger(), existing.dayKey == today else {
            return DailyAllowanceLedger(dayKey: today)
        }
        return existing
    }

    private func processAllowanceRequests(
        config: NightLockConfig,
        ledger: inout DailyAllowanceLedger,
        now: Date
    ) {
        let fileManager = FileManager.default
        let limits = config.allowanceLimits
        guard !limits.isEmpty,
              let files = try? fileManager.contentsOfDirectory(atPath: NightLockPaths.allowanceRequests)
        else { return }

        for filename in files where filename.hasSuffix(".json") {
            let path = NightLockPaths.allowanceRequests + "/" + filename
            defer { try? fileManager.removeItem(atPath: path) }

            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let request = try? NightLockFiles.decoder.decode(AllowanceActivityRequest.self, from: data),
                  abs(request.createdAt.timeIntervalSince(now)) <= 10,
                  let domain = NightLockFiles.allowanceKey(for: request.domain),
                  let minuteLimit = limits[domain],
                  minuteLimit > 0,
                  config.accessMode(for: domain, at: now) == .allowance
            else { continue }

            var entry = ledger.entries[domain] ?? DailyAllowanceEntry()
            let limitSeconds = Double(minuteLimit * 60)
            guard entry.usedSeconds < limitSeconds else { continue }

            if entry.startedAt == nil {
                // Preserve any time accumulated by the older active-tab tracker.
                entry.startedAt = request.createdAt.addingTimeInterval(-entry.usedSeconds)
            }
            entry.lastHeartbeat = request.createdAt
            ledger.entries[domain] = entry
        }
    }

    private func openAllowanceDomains(
        config: NightLockConfig,
        ledger: DailyAllowanceLedger,
        now: Date
    ) -> Set<String> {
        let limits = config.allowanceLimits
        return Set(config.managedDomains.filter { domain in
            if ledger.isBypassedForDay(domain) { return true }
            switch config.accessMode(for: domain, at: now) {
            case .unrestricted:
                return true
            case .allowance:
                return ledger.hasActiveWindow(for: domain, limits: limits, at: now)
            case .blocked:
                return false
            }
        })
    }

    private func processRequests(
        config: inout NightLockConfig,
        ledger: inout DailyAllowanceLedger,
        now: Date
    ) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(atPath: NightLockPaths.requests) else { return }

        for filename in files where filename.hasSuffix(".json") {
            let path = NightLockPaths.requests + "/" + filename
            defer { try? fileManager.removeItem(atPath: path) }

            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                if let request = try? NightLockFiles.decoder.decode(ProtectedUpdateRequest.self, from: data) {
                    processSettingsRequest(request, config: &config, now: now)
                } else if let request = try? NightLockFiles.decoder.decode(ProtectedAllowanceResetRequest.self, from: data) {
                    processAllowanceResetRequest(request, config: config, ledger: &ledger, now: now)
                } else if let request = try? NightLockFiles.decoder.decode(ProtectedDailyBypassRequest.self, from: data) {
                    processDailyBypassRequest(request, config: config, ledger: &ledger, now: now)
                } else {
                    lastRequestMessage = "Rejected malformed protected request."
                }
            } catch {
                lastRequestMessage = "Rejected malformed settings request."
            }
        }
    }

    private func processSettingsRequest(
        _ request: ProtectedUpdateRequest,
        config: inout NightLockConfig,
        now: Date
    ) {
        guard abs(request.createdAt.timeIntervalSince(now)) < 600 else {
            lastRequestMessage = "Rejected an expired settings request."
            return
        }
        guard recoveryKeyIsValid(request.recoveryKey, config: config) else {
            lastRequestMessage = "Rejected settings change: recovery key was incorrect."
            return
        }
        guard valid(hour: request.startHour, minute: request.startMinute),
              valid(hour: request.endHour, minute: request.endMinute)
        else {
            lastRequestMessage = "Rejected settings change: schedule was invalid."
            return
        }

        config.enabled = request.enabled
        config.startHour = request.startHour
        config.startMinute = request.startMinute
        config.endHour = request.endHour
        config.endMinute = request.endMinute
        do {
            try writeJSON(config, to: NightLockPaths.config, permissions: 0o644)
            lastRequestMessage = "Protected settings updated successfully."
        } catch {
            lastRequestMessage = "Could not save protected settings."
        }
    }

    private func processAllowanceResetRequest(
        _ request: ProtectedAllowanceResetRequest,
        config: NightLockConfig,
        ledger: inout DailyAllowanceLedger,
        now: Date
    ) {
        guard abs(request.createdAt.timeIntervalSince(now)) < 600 else {
            lastRequestMessage = "Rejected an expired allowance reset."
            return
        }
        guard recoveryKeyIsValid(request.recoveryKey, config: config) else {
            lastRequestMessage = "Rejected allowance reset: recovery key was incorrect."
            return
        }
        guard let domain = NightLockFiles.allowanceKey(for: request.domain),
              (config.allowanceLimits[domain] ?? 0) > 0
        else {
            lastRequestMessage = "Rejected allowance reset: site has no daily timer."
            return
        }

        ledger.entries.removeValue(forKey: domain)
        lastRequestMessage = "Reset \(domain) allowance successfully."
    }

    private func processDailyBypassRequest(
        _ request: ProtectedDailyBypassRequest,
        config: NightLockConfig,
        ledger: inout DailyAllowanceLedger,
        now: Date
    ) {
        guard abs(request.createdAt.timeIntervalSince(now)) < 600 else {
            lastRequestMessage = "Rejected an expired daily exemption."
            return
        }
        guard recoveryKeyIsValid(request.recoveryKey, config: config) else {
            lastRequestMessage = "Rejected daily exemption: recovery key was incorrect."
            return
        }
        guard let domain = NightLockFiles.allowanceKey(for: request.domain),
              (config.allowanceLimits[domain] ?? 0) > 0
        else {
            lastRequestMessage = "Rejected daily exemption: site has no daily timer."
            return
        }

        var entry = ledger.entries[domain] ?? DailyAllowanceEntry()
        entry.bypassedForDay = true
        ledger.entries[domain] = entry
        lastRequestMessage = "Exempted \(domain) for the rest of today successfully."
    }

    private func recoveryKeyIsValid(_ key: String, config: NightLockConfig) -> Bool {
        RecoveryKeyVerifier.verify(
            key: key,
            salt: config.recoverySalt,
            expectedHash: config.recoveryHash
        )
    }

    private func valid(hour: Int, minute: Int) -> Bool {
        (0 ... 23).contains(hour) && (0 ... 59).contains(minute)
    }

    private func enforceHosts(
        config: NightLockConfig,
        active: Bool,
        activeAllowances: Set<String>
    ) throws -> Bool {
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
            let blockedHosts = config.blockedHosts.filter { host in
                !activeAllowances.contains(where: { NightLockFiles.host(host, belongsToAllowance: $0) })
            }
            filtered.append("")
            filtered.append(beginMarker)
            filtered.append("# Managed by NightLock. Protected schedule: \(config.schedule.displayText)")
            filtered.append("127.0.0.1 " + blockedHosts.joined(separator: " "))
            filtered.append("::1 " + blockedHosts.joined(separator: " "))
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

    private func writeStatus(
        config: NightLockConfig,
        active: Bool,
        ledger: DailyAllowanceLedger
    ) throws {
        let limits = config.allowanceLimits
        let remaining = Dictionary(uniqueKeysWithValues: limits.keys.map { domain in
            (domain, ledger.remainingSeconds(for: domain, limits: limits, at: Date()))
        })
        let bypasses = limits.keys.filter { ledger.isBypassedForDay($0) }.sorted()
        let accessModes = Dictionary(uniqueKeysWithValues: config.managedDomains.map { domain in
            (domain, config.accessMode(for: domain, at: Date()))
        })
        let status = NightLockStatus(
            active: active,
            enabled: config.enabled,
            schedule: config.schedule.displayText,
            lastRequestMessage: lastRequestMessage,
            allowanceRemainingSeconds: remaining,
            dailyBypassDomains: bypasses,
            siteAccessModes: accessModes
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
