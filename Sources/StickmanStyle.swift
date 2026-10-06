import AppKit

/// Native macOS styling for Stickman's panels. Colors are semantic or appearance-aware,
/// so every surface follows light and dark mode. Views draw these colors in `draw(_:)`
/// rather than caching `cgColor`s, which would go stale when the appearance changes.
enum StickmanStyle {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let primaryText = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let tertiaryText = NSColor.tertiaryLabelColor

    static let cardFill = dynamic(light: NSColor.white.withAlphaComponent(0.58), dark: NSColor.white.withAlphaComponent(0.06))
    static let cardStroke = dynamic(light: NSColor.black.withAlphaComponent(0.07), dark: NSColor.white.withAlphaComponent(0.09))
    static let assistantBubble = dynamic(light: NSColor.black.withAlphaComponent(0.055), dark: NSColor.white.withAlphaComponent(0.1))
    static let fieldFill = dynamic(light: NSColor.white.withAlphaComponent(0.66), dark: NSColor.white.withAlphaComponent(0.07))
    static let fieldStroke = dynamic(light: NSColor.black.withAlphaComponent(0.1), dark: NSColor.white.withAlphaComponent(0.13))
    static let hairline = dynamic(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.1))
    static let panelEdge = dynamic(light: NSColor.white.withAlphaComponent(0.6), dark: NSColor.white.withAlphaComponent(0.16))
    static let hoverFill = dynamic(light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.white.withAlphaComponent(0.1))
    static let disabledFill = dynamic(light: NSColor.black.withAlphaComponent(0.09), dark: NSColor.white.withAlphaComponent(0.12))
    static let codeFill = dynamic(light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.white.withAlphaComponent(0.12))
    /// Stand-in for the live blur in offscreen preview renders, which cannot capture it.
    static let previewBackdrop = dynamic(light: NSColor(calibratedWhite: 0.95, alpha: 0.97), dark: NSColor(calibratedWhite: 0.16, alpha: 0.97))

    static func configurePrimaryButton(_ button: NSButton) {
        resetButton(button)
        button.bezelColor = .controlAccentColor
    }

    static func configureSecondaryButton(_ button: NSButton) {
        resetButton(button)
    }

    static func configureDangerButton(_ button: NSButton) {
        resetButton(button)
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [.foregroundColor: NSColor.systemRed, .font: button.font ?? .systemFont(ofSize: 13)]
        )
    }

    static func configureInputField(_ field: NSTextField) {
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.focusRingType = .default
        field.font = .systemFont(ofSize: 13)
    }

    private static func resetButton(_ button: NSButton) {
        button.isBordered = true
        button.bezelStyle = .rounded
        button.bezelColor = nil
        button.contentTintColor = nil
        button.attributedTitle = NSAttributedString(string: button.title)
        button.focusRingType = .default
    }
}

/// Borderless SF Symbol button with a soft hover highlight and an optional count badge.
class StickmanIconButton: NSButton {
    enum Fill {
        case plain
        case accent
        case destructive
    }

    var fill: Fill = .plain { didSet { applyTint(); needsDisplay = true } }
    var badgeCount = 0 { didSet { needsDisplay = true } }
    var isToggled = false { didSet { applyTint(); needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }

    init(symbol: String, label: String, pointSize: CGFloat = 14, weight: NSFont.Weight = .medium) {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .none
        setSymbol(symbol, label: label, pointSize: pointSize, weight: weight)
        applyTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSymbol(_ symbol: String, label: String, pointSize: CGFloat = 14, weight: NSFont.Weight = .medium) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(configuration)
        toolTip = label
        setAccessibilityLabel(label)
    }

    override var isEnabled: Bool { didSet { applyTint(); needsDisplay = true } }

    private func applyTint() {
        switch fill {
        case .plain:
            contentTintColor = isToggled ? .controlAccentColor : (isEnabled ? StickmanStyle.secondaryText : StickmanStyle.tertiaryText)
        case .accent:
            contentTintColor = isEnabled ? .white : StickmanStyle.tertiaryText
        case .destructive:
            contentTintColor = .white
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        switch fill {
        case .plain:
            if isToggled {
                NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
                circle.fill()
            } else if isHovered, isEnabled {
                StickmanStyle.hoverFill.setFill()
                circle.fill()
            }
        case .accent:
            if isEnabled {
                NSColor.controlAccentColor.withAlphaComponent(isHovered ? 0.88 : 1).setFill()
            } else {
                StickmanStyle.disabledFill.setFill()
            }
            circle.fill()
        case .destructive:
            NSColor.systemRed.withAlphaComponent(isHovered ? 0.88 : 1).setFill()
            circle.fill()
        }
        super.draw(dirtyRect)

        guard badgeCount > 0 else { return }
        let text = "\(badgeCount)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let badgeWidth = max(14, size.width + 7)
        let rect = NSRect(x: bounds.maxX - badgeWidth, y: isFlipped ? bounds.minY : bounds.maxY - 14, width: badgeWidth, height: 14)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
}

/// Rounded grouped-list surface.
class StickmanCardView: NSView {
    var cornerRadius: CGFloat = 12 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        StickmanStyle.cardFill.setFill()
        path.fill()
        StickmanStyle.cardStroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Capsule button used for suggestion chips.
final class StickmanChipButton: NSButton {
    private var isHovered = false { didSet { needsDisplay = true } }

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        focusRingType = .none
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var preferredWidth: CGFloat { attributedTitle.size().width + 24 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (isHovered ? StickmanStyle.hoverFill : StickmanStyle.fieldFill).setFill()
        path.fill()
        StickmanStyle.fieldStroke.setStroke()
        path.lineWidth = 1
        path.stroke()
        let size = attributedTitle.size()
        attributedTitle.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

/// Small circular avatar with Stickman's silhouette.
final class StickmanAvatarBadgeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        StickmanStyle.assistantBubble.setFill()
        circle.fill()
        StickmanStyle.hairline.setStroke()
        circle.stroke()

        let s = bounds.width / 28
        let ink = NSColor.labelColor
        ink.setStroke()
        let head = NSBezierPath(ovalIn: NSRect(x: 10.6 * s, y: 15.6 * s, width: 6.8 * s, height: 6.8 * s))
        head.lineWidth = 1.7 * s
        head.stroke()
        let body = NSBezierPath()
        body.lineWidth = 1.7 * s
        body.lineCapStyle = .round
        body.lineJoinStyle = .round
        body.move(to: NSPoint(x: 14 * s, y: 15.6 * s)); body.line(to: NSPoint(x: 14 * s, y: 10 * s))
        body.move(to: NSPoint(x: 9.4 * s, y: 11.4 * s)); body.line(to: NSPoint(x: 14 * s, y: 14 * s)); body.line(to: NSPoint(x: 18.6 * s, y: 11.4 * s))
        body.move(to: NSPoint(x: 10.6 * s, y: 5.4 * s)); body.line(to: NSPoint(x: 14 * s, y: 10 * s)); body.line(to: NSPoint(x: 17.4 * s, y: 5.4 * s))
        body.stroke()
    }
}

enum StickmanPanelShape {
    static let cornerRadius: CGFloat = 18
    static let tailWidth: CGFloat = 10
    static let tailHalfHeight: CGFloat = 10

    enum TailSide: Equatable {
        case none
        case left(y: CGFloat)
        case right(y: CGFloat)
    }

    /// Rounded rectangle with an optional speech-bubble tail, in unflipped coordinates.
    static func path(in bounds: NSRect, tail: TailSide) -> NSBezierPath {
        var body = bounds
        switch tail {
        case .none: break
        case .left: body.origin.x += tailWidth; body.size.width -= tailWidth
        case .right: body.size.width -= tailWidth
        }
        let path = NSBezierPath(roundedRect: body, xRadius: cornerRadius, yRadius: cornerRadius)
        let tailPath = NSBezierPath()
        switch tail {
        case .none:
            return path
        case .left(let y):
            let clampedY = min(max(y, body.minY + cornerRadius + tailHalfHeight), body.maxY - cornerRadius - tailHalfHeight)
            tailPath.move(to: NSPoint(x: body.minX + 1, y: clampedY + tailHalfHeight))
            tailPath.curve(to: NSPoint(x: bounds.minX, y: clampedY), controlPoint1: NSPoint(x: body.minX - 3, y: clampedY + 4), controlPoint2: NSPoint(x: bounds.minX + 2, y: clampedY + 1))
            tailPath.curve(to: NSPoint(x: body.minX + 1, y: clampedY - tailHalfHeight), controlPoint1: NSPoint(x: bounds.minX + 2, y: clampedY - 1), controlPoint2: NSPoint(x: body.minX - 3, y: clampedY - 4))
        case .right(let y):
            let clampedY = min(max(y, body.minY + cornerRadius + tailHalfHeight), body.maxY - cornerRadius - tailHalfHeight)
            tailPath.move(to: NSPoint(x: body.maxX - 1, y: clampedY + tailHalfHeight))
            tailPath.curve(to: NSPoint(x: bounds.maxX, y: clampedY), controlPoint1: NSPoint(x: body.maxX + 3, y: clampedY + 4), controlPoint2: NSPoint(x: bounds.maxX - 2, y: clampedY + 1))
            tailPath.curve(to: NSPoint(x: body.maxX - 1, y: clampedY - tailHalfHeight), controlPoint1: NSPoint(x: bounds.maxX - 2, y: clampedY - 1), controlPoint2: NSPoint(x: body.maxX + 3, y: clampedY - 4))
        }
        tailPath.close()
        path.append(tailPath)
        return path
    }
}

/// Frosted, appearance-aware panel background with a hairline edge and optional tail.
final class StickmanGlassView: NSView {
    var tail: StickmanPanelShape.TailSide = .none { didSet { if tail != oldValue { updateShape() } } }
    /// Offscreen previews cannot capture the live blur; draw an opaque stand-in instead.
    var rendersPreviewBackdrop = false { didSet { effectView.isHidden = rendersPreviewBackdrop; needsDisplay = true } }

    private let effectView = NSVisualEffectView()
    private let outline = OutlineView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.autoresizingMask = [.width, .height]
        effectView.frame = bounds
        outline.autoresizingMask = [.width, .height]
        outline.frame = bounds
        addSubview(effectView)
        addSubview(outline)
        updateShape()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Content goes between the blur and the outline.
    func addContent(_ view: NSView) {
        addSubview(view, positioned: .below, relativeTo: outline)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateShape()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard rendersPreviewBackdrop else { return }
        StickmanStyle.previewBackdrop.setFill()
        StickmanPanelShape.path(in: bounds, tail: tail).fill()
    }

    private func updateShape() {
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }
        let tail = self.tail
        effectView.maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            StickmanPanelShape.path(in: rect, tail: tail).fill()
            return true
        }
        outline.tail = tail
        outline.needsDisplay = true
        needsDisplay = true
        window?.invalidateShadow()
    }

    private final class OutlineView: NSView {
        var tail: StickmanPanelShape.TailSide = .none

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            let path = StickmanPanelShape.path(in: bounds.insetBy(dx: 0.5, dy: 0.5), tail: tail)
            path.lineWidth = 1
            StickmanStyle.panelEdge.setStroke()
            path.stroke()
        }
    }
}

/// Renders the inline Markdown that models commonly return.
enum StickmanMarkdown {
    static func render(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 4
        let source = normalizeBlocks(text)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        }

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let substring = String(parsed[run.range].characters)
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .paragraphStyle: paragraph]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                    attributes[.backgroundColor] = StickmanStyle.codeFill
                }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    runFont = NSFont(descriptor: runFont.fontDescriptor.withSymbolicTraits(traits), size: runFont.pointSize) ?? runFont
                }
                if intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            if let link = run.link {
                attributes[.link] = link
            }
            attributes[.font] = runFont
            result.append(NSAttributedString(string: substring, attributes: attributes))
        }
        return result
    }

    /// Turns list markers into bullets and headings into bold lines, since only inline syntax is parsed.
    private static func normalizeBlocks(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = String(line.prefix(while: { $0 == " " }))
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return indent + "• " + trimmed.dropFirst(2)
            }
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? line : "**\(title)**"
            }
            return line
        }
        .joined(separator: "\n")
    }
}
