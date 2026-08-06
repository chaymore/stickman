import AppKit

enum StickmanReferenceComparisonRenderer {
    static func render(root: URL, to outputURL: URL) throws {
        let imageSize = NSSize(width: 920, height: 560)
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
        drawTitle()

        let referenceRect = NSRect(x: 44, y: 86, width: 360, height: 360)
        let stickmanRect = NSRect(x: 516, y: 86, width: 220, height: 220)
        drawReference(root: root, in: referenceRect)
        drawStickman(in: stickmanRect)
        drawChecklist()

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewError.encodingFailed
        }

        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: outputURL, options: .atomic)
    }

    private static func drawTitle() {
        drawText(
            "Clawd Reference Comparison",
            at: CGPoint(x: 44, y: 26),
            attributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: AnthropicStyle.ink
            ]
        )
        drawText(
            "Left: public sticker artwork. Right: current native Stickman neutral render.",
            at: CGPoint(x: 44, y: 54),
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: AnthropicStyle.mutedInk
            ]
        )
    }

    private static func drawReference(root: URL, in rect: NSRect) {
        let referenceURL = root
            .appendingPathComponent("DesignConcepts/StickmanPreview/references", isDirectory: true)
            .appendingPathComponent("clawd-sticker-reference.png")

        drawCard(rect)
        if let image = NSImage(contentsOf: referenceURL) {
            let fitRect = aspectFitRect(aspectRatio: image.size, inside: rect.insetBy(dx: 20, dy: 20))
            drawImage(image, in: fitRect)
        } else {
            drawText(
                "Missing reference image",
                at: CGPoint(x: rect.minX + 24, y: rect.midY - 8),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: AnthropicStyle.clayDark
                ]
            )
        }
        drawText(
            "Reference",
            at: CGPoint(x: rect.minX, y: rect.maxY + 16),
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: AnthropicStyle.ink
            ]
        )
    }

    private static func drawStickman(in rect: NSRect) {
        drawCard(rect)
        let view = StickmanView(frame: NSRect(origin: .zero, size: rect.size))
        view.setPreviewState(.idle, time: 0.55)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.translateBy(x: rect.minX, y: rect.minY)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        drawText(
            "Stickman native",
            at: CGPoint(x: rect.minX, y: rect.maxY + 16),
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: AnthropicStyle.ink
            ]
        )
    }

    private static func drawChecklist() {
        let x: CGFloat = 516
        let y: CGFloat = 340
        let rows = [
            "Flat orange rectangle body",
            "One tab per side",
            "Four short legs",
            "Two black square eyes",
            "No default mouth or accessories",
            "State accents stay temporary"
        ]

        drawText(
            "Fit Checklist",
            at: CGPoint(x: x, y: y),
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: AnthropicStyle.ink
            ]
        )

        for (index, row) in rows.enumerated() {
            let rowY = y + 32 + CGFloat(index) * 24
            AnthropicStyle.clay.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: rowY + 4, width: 8, height: 8)).fill()
            drawText(
                row,
                at: CGPoint(x: x + 18, y: rowY),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: AnthropicStyle.mutedInk
                ]
            )
        }
    }

    private static func drawCard(_ rect: NSRect) {
        AnthropicStyle.panel.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        AnthropicStyle.line.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        border.lineWidth = 1
        border.stroke()
    }

    private static func aspectFitRect(aspectRatio: NSSize, inside rect: NSRect) -> NSRect {
        guard aspectRatio.width > 0, aspectRatio.height > 0 else { return rect }

        let scale = min(rect.width / aspectRatio.width, rect.height / aspectRatio.height)
        let width = aspectRatio.width * scale
        let height = aspectRatio.height * scale
        return NSRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func drawImage(_ image: NSImage, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        image.draw(in: NSRect(origin: .zero, size: rect.size))
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
