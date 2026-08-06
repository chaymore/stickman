import AppKit

enum StickmanWindowPreviewRenderer {
    static func render(to outputURL: URL) throws {
        let chatSize = NSSize(width: 500, height: 350)
        let settingsSize = NSSize(width: 560, height: 430)
        let padding: CGFloat = 24
        let titleHeight: CGFloat = 48
        let gap: CGFloat = 28
        let imageSize = NSSize(
            width: padding * 2 + chatSize.width + gap + settingsSize.width * 2 + gap,
            height: padding * 2 + titleHeight + max(chatSize.height, settingsSize.height)
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

        AnthropicStyle.parchment.setFill()
        NSRect(origin: .zero, size: imageSize).fill()
        drawText(
            "Stickman Interaction Window Preview",
            at: CGPoint(x: padding, y: 18),
            attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: AnthropicStyle.ink
            ]
        )
        drawText(
            "Anthropic-inspired cream surfaces, clay actions, compact AppKit controls.",
            at: CGPoint(x: padding + 300, y: 22),
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: AnthropicStyle.mutedInk
            ]
        )

        let chatPanel = StickmanChatPanelView(frame: NSRect(origin: .zero, size: chatSize))
        chatPanel.layoutSubtreeIfNeeded()
        drawPanel(chatPanel, title: "Chat", at: CGPoint(x: padding, y: padding + titleHeight), size: chatSize)

        let settingsPanel = StickmanSettingsPanelView(frame: NSRect(origin: .zero, size: settingsSize))
        settingsPanel.showPermissionsForPreview()
        settingsPanel.layoutSubtreeIfNeeded()
        drawPanel(
            settingsPanel,
            title: "Settings · Permissions",
            at: CGPoint(x: padding + chatSize.width + gap, y: padding + titleHeight),
            size: settingsSize
        )

        let connectionsPanel = StickmanSettingsPanelView(frame: NSRect(origin: .zero, size: settingsSize))
        connectionsPanel.showConnectionsForPreview()
        connectionsPanel.layoutSubtreeIfNeeded()
        drawPanel(
            connectionsPanel,
            title: "Settings · Connections",
            at: CGPoint(x: padding + chatSize.width + gap + settingsSize.width + gap, y: padding + titleHeight),
            size: settingsSize
        )

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewError.encodingFailed
        }

        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: outputURL, options: .atomic)
    }

    private static func drawPanel(_ panel: NSView, title: String, at origin: CGPoint, size: NSSize) {
        drawText(
            title,
            at: CGPoint(x: origin.x, y: origin.y - 20),
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: AnthropicStyle.ink
            ]
        )

        guard let panelBitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) else { return }
        panel.cacheDisplay(in: panel.bounds, to: panelBitmap)

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y + size.height)
        context.scaleBy(x: 1, y: -1)
        panelBitmap.draw(in: NSRect(origin: .zero, size: size))
        context.restoreGState()
    }

    private static func drawText(
        _ text: String,
        at point: CGPoint,
        attributes: [NSAttributedString.Key: Any]
    ) {
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
