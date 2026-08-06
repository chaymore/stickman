import Foundation

enum LegacyMigrationService {
    private static let migrationKey = "StickmanDidMigrateMiloDataV1"
    private static let legacyBundleIdentifier = "com.calebhaymore.Milo"

    static func runIfNeeded(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        migrateDefaults(into: defaults)
        migrateApplicationSupport(using: fileManager)
        defaults.set(true, forKey: migrationKey)
    }

    private static func migrateDefaults(into defaults: UserDefaults) {
        guard let legacyValues = defaults.persistentDomain(forName: legacyBundleIdentifier) else { return }
        for (key, value) in legacyValues {
            let newKey = key.replacingOccurrences(of: "Milo", with: "Stickman")
            if defaults.object(forKey: newKey) == nil {
                defaults.set(value, forKey: newKey)
            }
        }
    }

    private static func migrateApplicationSupport(using fileManager: FileManager) {
        guard let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let legacyDirectory = supportRoot.appendingPathComponent("Milo", isDirectory: true)
        let currentDirectory = supportRoot.appendingPathComponent("Stickman", isDirectory: true)
        guard fileManager.fileExists(atPath: legacyDirectory.path) else { return }

        try? fileManager.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        guard let items = try? fileManager.contentsOfDirectory(
            at: legacyDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for source in items {
            let destination = currentDirectory.appendingPathComponent(source.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.copyItem(at: source, to: destination)
        }
    }
}
