import AppKit

/// Renders the chat and settings panels in light and dark mode beside Stickman.
/// The live frosted blur cannot be captured offscreen, so panels use an opaque stand-in.
enum StickmanWindowPreviewRenderer {
    static func render(to outputURL: URL) throws {
        let tail = StickmanPanelShape.tailWidth
        let chatSize = NSSize(width: StickmanCompanionPanelController.chatSize.width + tail, height: StickmanCompanionPanelController.chatSize.height)
        let settingsSize = NSSize(width: StickmanCompanionPanelController.settingsSize.width + tail, height: StickmanCompanionPanelController.settingsSize.height)
        let character = StickmanMetrics.characterSize
        let padding: CGFloat = 32
        let gap: CGFloat = 36
        let titleHeight: CGFloat = 52
        let rowHeight = max(chatSize.height, settingsSize.height) + 34
        let imageSize = NSSize(
            width: padding * 2 + character * 0.6 + chatSize.width + gap + settingsSize.width * 2 + gap,
            height: padding + titleHeight + rowHeight * 2 + padding
        )

        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(imageSize.width),
                pixelsHigh: Int(imageSize.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bitmapFormat: [.alphaFirst],
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            throw PreviewError.encodingFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.cgContext.translateBy(x: 0, y: imageSize.height)
        graphicsContext.cgContext.scaleBy(x: 1, y: -1)
        defer { NSGraphicsContext.restoreGraphicsState() }

        PreviewPalette.background.setFill()
        NSRect(origin: .zero, size: imageSize).fill()
        drawText(
            "Stickman Panels",
            at: CGPoint(x: padding, y: 22),
            attributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: PreviewPalette.ink]
        )
        drawText(
            "Native glass in light and dark mode. Offscreen renders use an opaque stand-in for the live blur.",
            at: CGPoint(x: padding + 160, y: 26),
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: PreviewPalette.muted]
        )

        for (rowIndex, appearanceName) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            guard let appearance = NSAppearance(named: appearanceName) else { continue }
            let rowY = padding + titleHeight + CGFloat(rowIndex) * rowHeight
            let rowRect = NSRect(x: padding - 12, y: rowY - 8, width: imageSize.width - padding * 2 + 24, height: rowHeight - 10)
            drawDesktop(in: rowRect, dark: rowIndex == 1)

            var x = padding + character * 0.6
            let panelY = rowY + 18

            let stickman = StickmanView(frame: NSRect(x: 0, y: 0, width: character, height: character))
            stickman.setPreviewState(.listening, time: 0.4)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.translateBy(x: x - character * 0.5 - 10, y: panelY + chatSize.height - character + StickmanMetrics.footInset - 4)
            stickman.draw(stickman.bounds)
            NSGraphicsContext.restoreGraphicsState()

            let chat = StickmanChatPanelView(frame: NSRect(origin: .zero, size: StickmanCompanionPanelController.chatSize))
            chat.loadPreviewConversation()
            drawPanel(chat, size: chatSize, at: CGPoint(x: x, y: panelY), appearance: appearance, label: rowIndex == 0 ? "Chat" : nil)
            x += chatSize.width + gap

            let general = StickmanSettingsPanelView(frame: NSRect(origin: .zero, size: StickmanCompanionPanelController.settingsSize))
            drawPanel(general, size: settingsSize, at: CGPoint(x: x, y: panelY), appearance: appearance, label: rowIndex == 0 ? "Settings · General" : nil)
            x += settingsSize.width + gap

            let claudeCode = StickmanSettingsPanelView(frame: NSRect(origin: .zero, size: StickmanCompanionPanelController.settingsSize))
            claudeCode.showClaudeCodeForPreview()
            drawPanel(claudeCode, size: settingsSize, at: CGPoint(x: x, y: panelY), appearance: appearance, label: rowIndex == 0 ? "Settings · Claude Code" : nil)
        }

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewError.encodingFailed
        }

        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: outputURL, options: .atomic)
    }

    private static func drawDesktop(in rect: NSRect, dark: Bool) {
        let colors = dark
            ? [NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.20, alpha: 1), NSColor(calibratedRed: 0.20, green: 0.16, blue: 0.28, alpha: 1)]
            : [NSColor(calibratedRed: 0.72, green: 0.80, blue: 0.90, alpha: 1), NSColor(calibratedRed: 0.90, green: 0.84, blue: 0.86, alpha: 1)]
        let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        NSGradient(colors: colors)?.draw(in: path, angle: -30)
    }

    private static func drawPanel(_ content: NSView, size: NSSize, at origin: CGPoint, appearance: NSAppearance, label: String?) {
        if let label {
            drawText(label, at: CGPoint(x: origin.x + 12, y: origin.y - 22), attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: PreviewPalette.ink
            ])
        }
        let glass = StickmanGlassView(frame: NSRect(origin: .zero, size: size))
        glass.rendersPreviewBackdrop = true
        glass.tail = .left(y: size.height - 70)
        content.frame = NSRect(x: StickmanPanelShape.tailWidth, y: 0, width: size.width - StickmanPanelShape.tailWidth, height: size.height)
        glass.addContent(content)
        drawView(glass, at: origin, appearance: appearance, clip: StickmanPanelShape.path(in: glass.bounds, tail: glass.tail))
    }

    private static func drawView(_ view: NSView, at origin: CGPoint, appearance: NSAppearance, clip: NSBezierPath) {
        view.appearance = appearance
        var bitmap: NSBitmapImageRep?
        appearance.performAsCurrentDrawingAppearance {
            view.layoutSubtreeIfNeeded()
            bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            if let bitmap { view.cacheDisplay(in: view.bounds, to: bitmap) }
        }
        guard let bitmap, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y + view.bounds.height)
        context.scaleBy(x: 1, y: -1)
        // Layer-backed views cache with opaque corners; clip to the panel's real shape.
        clip.addClip()
        bitmap.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        context.restoreGState()
    }

    private static func drawText(_ text: String, at point: CGPoint, attributes: [NSAttributedString.Key: Any]) {
        let size = text.size(withAttributes: attributes)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: point.x, y: point.y + size.height)
        context.scaleBy(x: 1, y: -1)
        text.draw(at: .zero, withAttributes: attributes)
        context.restoreGState()
    }

    enum PreviewError: Error {
        case encodingFailed
    }
}
