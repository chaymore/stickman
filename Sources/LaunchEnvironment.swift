import Foundation

/// Sets up the environment the app bundle used to get from a launcher script: API keys from
/// the login keychain and the bundled system prompt. Running the binary directly keeps macOS
/// privacy grants (Accessibility, Screen Recording) attached to the process that uses them.
enum LaunchEnvironment {
    static func prepare() {
        loadKey("OPENAI_API_KEY", services: ["Stickman OpenAI API Key", "Milo OpenAI API Key"])
        loadKey("OPENROUTER_API_KEY", services: ["Stickman OpenRouter API Key", "Milo OpenRouter API Key"])

        guard let resources = Bundle.main.resourcePath,
              FileManager.default.fileExists(atPath: resources + "/STICKMAN_SYSTEM_PROMPT.md")
        else { return }
        setIfUnset("STICKMAN_PROJECT_DIR", resources)
        setIfUnset("STICKMAN_SYSTEM_PROMPT_PATH", resources + "/STICKMAN_SYSTEM_PROMPT.md")
    }

    /// Reads through `security` so keychain items it created stay readable without a prompt,
    /// even though ad-hoc builds change the app's code identity.
    private static func loadKey(_ variable: String, services: [String]) {
        guard ProcessInfo.processInfo.environment[variable]?.isEmpty ?? true else { return }
        let account = NSUserName()
        for service in services {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-a", account, "-s", service, "-w"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0, !value.isEmpty {
                setenv(variable, value, 1)
                return
            }
        }
    }

    private static func setIfUnset(_ variable: String, _ value: String) {
        if ProcessInfo.processInfo.environment[variable]?.isEmpty ?? true { setenv(variable, value, 1) }
    }
}
