import AppKit

enum AnthropicStyle {
    static let ink = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.09, alpha: 1)
    static let mutedInk = NSColor(calibratedRed: 0.38, green: 0.35, blue: 0.31, alpha: 1)
    static let cream = NSColor(calibratedRed: 0.96, green: 0.94, blue: 0.88, alpha: 1)
    static let parchment = NSColor(calibratedRed: 0.91, green: 0.87, blue: 0.78, alpha: 1)
    static let panel = NSColor(calibratedRed: 0.99, green: 0.97, blue: 0.92, alpha: 0.96)
    static let inset = NSColor(calibratedRed: 0.98, green: 0.95, blue: 0.88, alpha: 1)
    static let line = NSColor(calibratedRed: 0.70, green: 0.61, blue: 0.50, alpha: 0.48)
    static let clay = NSColor(calibratedRed: 0.82, green: 0.43, blue: 0.31, alpha: 1)
    static let clayDark = NSColor(calibratedRed: 0.56, green: 0.25, blue: 0.18, alpha: 1)
    static let claySoft = NSColor(calibratedRed: 0.93, green: 0.72, blue: 0.62, alpha: 1)
    static let control = NSColor(calibratedRed: 1.00, green: 0.98, blue: 0.93, alpha: 0.88)
    static let controlHover = NSColor(calibratedRed: 0.95, green: 0.90, blue: 0.82, alpha: 0.95)

    static func configurePanelLayer(_ layer: CALayer?) {
        layer?.backgroundColor = panel.cgColor
        layer?.cornerRadius = 14
        layer?.borderColor = line.cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -4)
    }

    static func configureSecondaryButton(_ button: NSButton) {
        configureButton(
            button,
            foreground: mutedInk,
            background: control,
            border: line,
            weight: .medium
        )
    }

    static func configurePrimaryButton(_ button: NSButton) {
        configureButton(
            button,
            foreground: cream,
            background: clay,
            border: clayDark.withAlphaComponent(0.24),
            weight: .semibold
        )
    }

    static func configureDangerButton(_ button: NSButton) {
        configureButton(
            button,
            foreground: clayDark,
            background: claySoft.withAlphaComponent(0.34),
            border: clay.withAlphaComponent(0.28),
            weight: .medium
        )
    }

    static func configureInputField(_ field: NSTextField) {
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.72)
        field.textColor = ink
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
        field.layer?.cornerRadius = 8
        field.layer?.borderColor = line.cgColor
        field.layer?.borderWidth = 1
    }

    private static func configureButton(
        _ button: NSButton,
        foreground: NSColor,
        background: NSColor,
        border: NSColor,
        weight: NSFont.Weight
    ) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.wantsLayer = true
        button.layer?.backgroundColor = background.cgColor
        button.layer?.cornerRadius = 7
        button.layer?.borderColor = border.cgColor
        button.layer?.borderWidth = 1
        button.focusRingType = .none
        button.contentTintColor = foreground
        setButtonTitle(button, color: foreground, weight: weight)
    }

    static func setButtonTitle(
        _ button: NSButton,
        color: NSColor,
        weight: NSFont.Weight
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 12, weight: weight)
        ]
        button.attributedTitle = NSAttributedString(string: button.title, attributes: attributes)
    }
}
