import AppKit
import Darwin
import Foundation
import NightLockCore

final class SettingsWindowController: NSWindowController {
    private let enabledCheckbox = NSButton(checkboxWithTitle: "Enforcement enabled", target: nil, action: nil)
    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private let keyField = NSSecureTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "NightLock Protected Settings"
        window.center()
        super.init(window: window)
        configureUI()
        loadCurrentSettings()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureUI() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Protected Schedule")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let explanation = NSTextField(wrappingLabelWithString: "Changes require the split emergency recovery key. There is no snooze or quick override.")
        explanation.textColor = .secondaryLabelColor

        configurePicker(startPicker)
        configurePicker(endPicker)
        keyField.placeholderString = "64-character recovery key"

        let startLabel = NSTextField(labelWithString: "Starts every day")
        let endLabel = NSTextField(labelWithString: "Ends every day")
        let keyLabel = NSTextField(labelWithString: "Recovery key")
        let apply = NSButton(title: "Apply Protected Changes", target: self, action: #selector(applyChanges))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"

        let views = [title, explanation, enabledCheckbox, startLabel, startPicker, endLabel, endPicker, keyLabel, keyField, apply, statusLabel]
        views.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            explanation.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            explanation.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            enabledCheckbox.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 20),
            enabledCheckbox.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            startLabel.topAnchor.constraint(equalTo: enabledCheckbox.bottomAnchor, constant: 20),
            startLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            startPicker.centerYAnchor.constraint(equalTo: startLabel.centerYAnchor),
            startPicker.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            endLabel.topAnchor.constraint(equalTo: startLabel.bottomAnchor, constant: 18),
            endLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            endPicker.centerYAnchor.constraint(equalTo: endLabel.centerYAnchor),
            endPicker.trailingAnchor.constraint(equalTo: startPicker.trailingAnchor),
            keyLabel.topAnchor.constraint(equalTo: endLabel.bottomAnchor, constant: 24),
            keyLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            keyField.topAnchor.constraint(equalTo: keyLabel.bottomAnchor, constant: 7),
            keyField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            keyField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            apply.topAnchor.constraint(equalTo: keyField.bottomAnchor, constant: 18),
            apply.trailingAnchor.constraint(equalTo: keyField.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: apply.bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: keyField.trailingAnchor),
        ])
    }

    private func configurePicker(_ picker: NSDatePicker) {
        picker.datePickerElements = [.hourMinute]
        picker.datePickerStyle = .textFieldAndStepper
    }

    private func loadCurrentSettings() {
        guard let config = try? NightLockFiles.loadConfig() else {
            statusLabel.stringValue = "Install the NightLock system helper first."
            return
        }
        enabledCheckbox.state = config.enabled ? .on : .off
        startPicker.dateValue = date(hour: config.startHour, minute: config.startMinute)
        endPicker.dateValue = date(hour: config.endHour, minute: config.endMinute)
    }

    @objc private func applyChanges() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            statusLabel.stringValue = "Recover and enter the emergency key before changing protected settings."
            return
        }

        let start = Calendar.current.dateComponents([.hour, .minute], from: startPicker.dateValue)
        let end = Calendar.current.dateComponents([.hour, .minute], from: endPicker.dateValue)
        let request = ProtectedUpdateRequest(
            recoveryKey: key,
            enabled: enabledCheckbox.state == .on,
            startHour: start.hour ?? 22,
            startMinute: start.minute ?? 0,
            endHour: end.hour ?? 5,
            endMinute: end.minute ?? 0
        )

        do {
            let data = try NightLockFiles.encoder.encode(request)
            let path = NightLockPaths.requests + "/\(request.id.uuidString).json"
            guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            keyField.stringValue = ""
            statusLabel.stringValue = "Protected request submitted. The daemon will validate and apply it within a few seconds."
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refreshResult() }
        } catch {
            statusLabel.stringValue = "Could not submit protected changes: \(error.localizedDescription)"
        }
    }

    private func refreshResult() {
        if let status = try? NightLockFiles.loadStatus(), let message = status.lastRequestMessage {
            statusLabel.stringValue = message
            if message.contains("successfully") { loadCurrentSettings() }
        }
    }

    private func date(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }
}
