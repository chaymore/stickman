import AppKit
import QuartzCore

/// GPU particle effects for landings and fights, drawn on the screen overlay.
/// Sprites mix a dark body with a light rim so they read on light and dark desktops.
@MainActor
enum StickmanParticles {
    // MARK: Effects

    /// A dust cloud rolling out along the ground, with grit kicked up and falling back.
    static func landingDust(in host: CALayer, at point: CGPoint, strength: CGFloat) {
        let s = max(0.3, min(1.6, strength))
        let emitter = makeEmitter(at: point, shape: .line, size: CGSize(width: 30 + 30 * s, height: 0))
        let dustLeft = dustCell(direction: .pi, count: 5 + 6 * s, speed: 80 + 70 * s)
        let dustRight = dustCell(direction: 0, count: 5 + 6 * s, speed: 80 + 70 * s)
        let rising = dustCell(direction: .pi / 2, count: 2 + 3 * s, speed: 30 + 20 * s)
        rising.emissionRange = 0.9
        let grit = cell(Sprites.grit, count: 6 + 12 * s, lifetime: 0.75, speed: 150 + 90 * s)
        grit.emissionLongitude = .pi / 2
        grit.emissionRange = 1.1
        grit.yAcceleration = -1100
        grit.scale = 0.5
        grit.scaleRange = 0.25
        grit.alphaSpeed = -1.0
        emitter.emitterCells = [dustLeft, dustRight, rising, grit]
        fire(emitter, in: host, burst: 0.06, lifetime: 1.8)

        if s > 1.05 {
            groundShockwave(in: host, at: point, strength: s)
        }
    }

    /// A punch or kick connecting: a flash, a shockwave, debris, sparks, and a puff of dust.
    static func impact(in host: CALayer, at point: CGPoint, strength: CGFloat) {
        let s = max(0.4, min(1.8, strength))
        flash(in: host, at: point, size: 110 * s, duration: 0.16)
        shockwave(in: host, at: point, size: 190 * s, duration: 0.45, squash: 1)

        let emitter = makeEmitter(at: point, shape: .point, size: .zero)
        let shards = cell(Sprites.shard, count: 12 + 12 * s, lifetime: 0.7, speed: 330 + 120 * s)
        shards.velocityRange = 160
        shards.emissionRange = .pi * 2
        shards.yAcceleration = -950
        shards.spin = 0
        shards.spinRange = 14
        shards.scale = 0.75
        shards.scaleRange = 0.35
        shards.alphaSpeed = -1.1

        let sparks = streaks(Sprites.sparkStreaks, within: nil, count: 22 + 18 * s, lifetime: 0.32, speed: 620 + 220 * s) { spark in
            spark.velocityRange = 260
            spark.yAcceleration = -420
            spark.scale = 0.75
            spark.scaleRange = 0.3
            spark.scaleSpeed = -1.6
            spark.alphaSpeed = -2.2
        }

        let puff = cell(Sprites.dust[1], count: 4 + 3 * s, lifetime: 0.9, speed: 50)
        puff.emissionRange = .pi * 2
        puff.scale = 0.22
        puff.scaleSpeed = 0.55
        puff.alphaSpeed = -0.9

        emitter.emitterCells = [puff, shards] + sparks
        fire(emitter, in: host, burst: 0.05, lifetime: 1.2)
    }

    /// A curved swoosh from Stickman toward the cursor, ending in a few sparks.
    static func slash(in host: CALayer, from start: CGPoint, to end: CGPoint) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(1, hypot(dx, dy))
        let normal = CGPoint(x: -dy / length, y: dx / length)
        let bulge = min(70, length * 0.22)

        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: CGPoint(x: (start.x + end.x) / 2 + normal.x * bulge, y: (start.y + end.y) / 2 + normal.y * bulge))
        path.addQuadCurve(to: start, control: CGPoint(x: (start.x + end.x) / 2 + normal.x * bulge * 0.45, y: (start.y + end.y) / 2 + normal.y * bulge * 0.45))
        path.closeSubpath()

        let bounds = path.boundingBoxOfPath.insetBy(dx: -4, dy: -4)
        var shift = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
        let swoosh = CAShapeLayer()
        swoosh.frame = CGRect(origin: .zero, size: bounds.size)
        swoosh.path = path.copy(using: &shift)
        swoosh.fillColor = NSColor.white.withAlphaComponent(0.92).cgColor
        swoosh.strokeColor = NSColor(calibratedWhite: 0.05, alpha: 0.6).cgColor
        swoosh.lineWidth = 1.5
        let fadeMask = CAGradientLayer()
        fadeMask.frame = swoosh.frame
        fadeMask.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.cgColor]
        fadeMask.startPoint = unitPoint(start, in: bounds)
        fadeMask.endPoint = unitPoint(end, in: bounds)
        let container = CALayer()
        container.frame = bounds
        container.addSublayer(swoosh)
        container.mask = fadeMask

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.addSublayer(container)
        CATransaction.commit()

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.45, 1]
        fade.duration = 0.34
        container.opacity = 0
        container.add(fade, forKey: "fade")
        remove(container, after: 0.37)

        let emitter = makeEmitter(at: end, shape: .point, size: .zero)
        emitter.emitterCells = streaks(Sprites.sparkStreaks, within: (atan2(dy, dx), 0.75), count: 12, lifetime: 0.26, speed: 420) { spark in
            spark.scale = 0.65
            spark.scaleSpeed = -1.8
            spark.alphaSpeed = -2.6
            spark.yAcceleration = -300
        }
        fire(emitter, in: host, burst: 0.04, lifetime: 0.5)
    }

    /// Squaring up for a fight splashes ink; a truce lets off a soft, rising puff.
    static func modeShift(in host: CALayer, at point: CGPoint, enteringCombat: Bool) {
        let emitter = makeEmitter(at: point, shape: .circle, size: CGSize(width: 24, height: 24))
        if enteringCombat {
            shockwave(in: host, at: point, size: 300, duration: 0.6, squash: 1)
            emitter.emitterCells = streaks(Sprites.inkStreaks, within: nil, count: 34, lifetime: 0.85, speed: 300) { ink in
                ink.velocityRange = 150
                ink.yAcceleration = -760
                ink.scale = 0.8
                ink.scaleRange = 0.35
                ink.scaleSpeed = -0.45
                ink.alphaSpeed = -0.8
            }
        } else {
            let puff = cell(Sprites.lightPuff, count: 16, lifetime: 1.3, speed: 70)
            puff.velocityRange = 40
            puff.emissionRange = .pi * 2
            puff.yAcceleration = 45
            puff.scale = 0.22
            puff.scaleRange = 0.08
            puff.scaleSpeed = 0.45
            puff.alphaSpeed = -0.65
            puff.spinRange = 1
            let motes = cell(Sprites.mote, count: 12, lifetime: 1.4, speed: 40)
            motes.emissionRange = .pi * 2
            motes.yAcceleration = 60
            motes.scale = 0.22
            motes.alphaSpeed = -0.6
            emitter.emitterCells = [puff, motes]
        }
        fire(emitter, in: host, burst: 0.06, lifetime: 1.8)
    }

    // MARK: Building blocks

    /// Emitter cells can't turn particles to face their velocity, so each cell owns a
    /// sprite pre-rotated to its narrow slice of directions.
    private static func streaks(
        _ sprites: [CGImage],
        within cone: (center: CGFloat, halfWidth: CGFloat)?,
        count: CGFloat,
        lifetime: Float,
        speed: CGFloat,
        configure: (CAEmitterCell) -> Void
    ) -> [CAEmitterCell] {
        let slice = 2 * CGFloat.pi / CGFloat(sprites.count)
        let chosen = sprites.indices.filter { index in
            guard let cone else { return true }
            let angle = CGFloat(index) * slice
            let difference = atan2(sin(angle - cone.center), cos(angle - cone.center))
            return abs(difference) <= cone.halfWidth
        }
        let perCell = count / CGFloat(max(1, chosen.count))
        return chosen.map { index in
            let streak = cell(sprites[index], count: perCell, lifetime: lifetime, speed: speed)
            streak.emissionLongitude = CGFloat(index) * slice
            streak.emissionRange = slice
            configure(streak)
            return streak
        }
    }

    private static func dustCell(direction: CGFloat, count: CGFloat, speed: CGFloat) -> CAEmitterCell {
        let dust = cell(Sprites.dust.randomElement() ?? Sprites.dust[0], count: count, lifetime: 1.1, speed: speed)
        dust.velocityRange = speed * 0.55
        dust.emissionLongitude = direction
        dust.emissionRange = 0.35
        // Air drag: slow the sideways roll, and let warm dust drift upward.
        dust.xAcceleration = -cos(direction) * speed * 0.8
        dust.yAcceleration = 28
        dust.scale = 0.42
        dust.scaleRange = 0.14
        dust.scaleSpeed = 0.75
        dust.alphaSpeed = -0.72
        dust.spinRange = 0.6
        dust.lifetimeRange = 0.4
        return dust
    }

    private static func cell(_ image: CGImage, count: CGFloat, lifetime: Float, speed: CGFloat) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = image
        cell.contentsScale = 2
        cell.birthRate = Float(count) / Burst.duration
        cell.lifetime = lifetime
        cell.lifetimeRange = lifetime * 0.3
        cell.velocity = speed
        cell.velocityRange = speed * 0.4
        return cell
    }

    private enum Burst {
        /// Cell birth rates are set so `count` particles appear over this window.
        static let duration: Float = 0.05
    }

    private static func makeEmitter(at point: CGPoint, shape: CAEmitterLayerEmitterShape, size: CGSize) -> CAEmitterLayer {
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = point
        emitter.emitterShape = shape
        emitter.emitterSize = size
        emitter.emitterMode = shape == .point ? .points : .outline
        emitter.renderMode = .oldestLast
        return emitter
    }

    private static func fire(_ emitter: CAEmitterLayer, in host: CALayer, burst: TimeInterval, lifetime: TimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.frame = host.bounds
        emitter.beginTime = CACurrentMediaTime()
        host.addSublayer(emitter)
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + burst) { emitter.birthRate = 0 }
        remove(emitter, after: lifetime)
    }

    private static func flash(in host: CALayer, at point: CGPoint, size: CGFloat, duration: CFTimeInterval) {
        let layer = spriteLayer(Sprites.flash, at: point, size: size)
        host.addSublayer(layer)
        animate(layer, scale: (0.3, 1.4), opacity: (1, 0), duration: duration)
        remove(layer, after: duration + 0.05)
    }

    private static func shockwave(in host: CALayer, at point: CGPoint, size: CGFloat, duration: CFTimeInterval, squash: CGFloat) {
        let layer = spriteLayer(Sprites.ring, at: point, size: size)
        layer.setAffineTransform(CGAffineTransform(scaleX: 1, y: squash))
        host.addSublayer(layer)
        animate(layer, scale: (0.15, 1), opacity: (0.9, 0), duration: duration, squash: squash)
        remove(layer, after: duration + 0.05)
    }

    /// A flattened ring rolling out along the ground for big landings.
    private static func groundShockwave(in host: CALayer, at point: CGPoint, strength: CGFloat) {
        shockwave(in: host, at: CGPoint(x: point.x, y: point.y + 2), size: 220 * strength, duration: 0.55, squash: 0.28)
    }

    private static func spriteLayer(_ image: CGImage, at point: CGPoint, size: CGFloat) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let layer = CALayer()
        layer.contents = image
        layer.contentsScale = 2
        layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        layer.position = point
        CATransaction.commit()
        return layer
    }

    private static func animate(
        _ layer: CALayer,
        scale: (CGFloat, CGFloat),
        opacity: (Float, Float),
        duration: CFTimeInterval,
        squash: CGFloat = 1
    ) {
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = CATransform3DMakeScale(scale.0, scale.0 * squash, 1)
        grow.toValue = CATransform3DMakeScale(scale.1, scale.1 * squash, 1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity.0
        fade.toValue = opacity.1
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "burst")
    }

    private static func remove(_ layer: CALayer, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { layer.removeFromSuperlayer() }
    }

    private static func unitPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: (point.x - rect.minX) / max(1, rect.width), y: (point.y - rect.minY) / max(1, rect.height))
    }

    // MARK: Sprites

    private enum Sprites {
        static let dust: [CGImage] = (0 ..< 3).map { dustPuff(seed: $0, light: false) }
        static let lightPuff = dustPuff(seed: 7, light: true)
        static let grit = render(size: 10) { context, size in
            context.setFillColor(NSColor(calibratedWhite: 0.92, alpha: 0.7).cgColor)
            context.fillEllipse(in: CGRect(x: 0.5, y: 0.5, width: size - 1, height: size - 1))
            context.setFillColor(NSColor(calibratedRed: 0.22, green: 0.2, blue: 0.18, alpha: 1).cgColor)
            context.fillEllipse(in: CGRect(x: 1.8, y: 1.8, width: size - 3.6, height: size - 3.6))
        }
        static let shard = render(size: 22) { context, _ in
            let path = CGMutablePath()
            path.addLines(between: [CGPoint(x: 3, y: 9), CGPoint(x: 19, y: 4), CGPoint(x: 15, y: 16), CGPoint(x: 6, y: 18)])
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(NSColor(calibratedWhite: 0.07, alpha: 1).cgColor)
            context.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.75).cgColor)
            context.setLineWidth(1.2)
            context.drawPath(using: .fillStroke)
        }
        static let sparkStreaks: [CGImage] = (0 ..< 16).map { index in
            streak(angle: CGFloat(index) / 16 * .pi * 2, length: 26, width: 3.2, core: .white, rim: NSColor(calibratedWhite: 0.05, alpha: 0.65))
        }
        static let inkStreaks: [CGImage] = (0 ..< 16).map { index in
            streak(angle: CGFloat(index) / 16 * .pi * 2, length: 18, width: 6, core: NSColor(calibratedWhite: 0.04, alpha: 1), rim: NSColor.white.withAlphaComponent(0.7))
        }
        static let mote = render(size: 12) { context, size in
            radial(context, size: size, stops: [
                (0, NSColor.white.withAlphaComponent(0.95)),
                (0.5, NSColor.white.withAlphaComponent(0.5)),
                (1, NSColor.white.withAlphaComponent(0))
            ])
        }
        static let flash = render(size: 128) { context, size in
            radial(context, size: size, stops: [
                (0, NSColor.white.withAlphaComponent(0.95)),
                (0.35, NSColor.white.withAlphaComponent(0.55)),
                (0.62, NSColor(calibratedWhite: 0.15, alpha: 0.18)),
                (1, NSColor(calibratedWhite: 0.15, alpha: 0))
            ])
        }
        static let ring = render(size: 256) { context, size in
            radial(context, size: size, stops: [
                (0, NSColor(calibratedWhite: 0.1, alpha: 0)),
                (0.74, NSColor(calibratedWhite: 0.1, alpha: 0)),
                (0.86, NSColor(calibratedWhite: 0.1, alpha: 0.42)),
                (0.92, NSColor.white.withAlphaComponent(0.4)),
                (1, NSColor.white.withAlphaComponent(0))
            ])
        }

        /// A soft, slightly uneven cloud: wide blobs packed close so they blend instead of clumping.
        private static func dustPuff(seed: Int, light: Bool) -> CGImage {
            render(size: 96) { context, size in
                var generator = SeededGenerator(seed: UInt64(seed + 1))
                let base = light ? NSColor(calibratedWhite: 0.97, alpha: 1) : NSColor(calibratedRed: 0.74, green: 0.71, blue: 0.66, alpha: 1)
                for _ in 0 ..< 4 {
                    let radius = size * CGFloat.random(in: 0.36 ... 0.46, using: &generator)
                    let center = CGPoint(
                        x: size / 2 + CGFloat.random(in: -size * 0.07 ... size * 0.07, using: &generator),
                        y: size / 2 + CGFloat.random(in: -size * 0.06 ... size * 0.06, using: &generator)
                    )
                    let colors = [base.withAlphaComponent(light ? 0.32 : 0.26).cgColor, base.withAlphaComponent(0).cgColor] as CFArray
                    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { continue }
                    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
                }
            }
        }

        /// A tapered streak along `angle`: bright head, fading tail, thin contrasting rim.
        private static func streak(angle: CGFloat, length: CGFloat, width: CGFloat, core: NSColor, rim: NSColor) -> CGImage {
            render(size: 32) { context, size in
                context.translateBy(x: size / 2, y: size / 2)
                context.rotate(by: angle)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: -length / 2, y: 0))
                path.addQuadCurve(to: CGPoint(x: length / 2 - width / 2, y: width / 2), control: CGPoint(x: 0, y: width * 0.35))
                path.addArc(center: CGPoint(x: length / 2 - width / 2, y: 0), radius: width / 2, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
                path.addQuadCurve(to: CGPoint(x: -length / 2, y: 0), control: CGPoint(x: 0, y: -width * 0.35))
                path.closeSubpath()
                context.addPath(path)
                context.setStrokeColor(rim.cgColor)
                context.setLineWidth(1.4)
                context.strokePath()
                context.addPath(path)
                context.clip()
                let colors = [core.withAlphaComponent(0).cgColor, core.cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.7]) {
                    context.drawLinearGradient(gradient, start: CGPoint(x: -length / 2, y: 0), end: CGPoint(x: length / 2, y: 0), options: [])
                }
            }
        }

        private static func radial(_ context: CGContext, size: CGFloat, stops: [(CGFloat, NSColor)]) {
            let colors = stops.map { $0.1.cgColor } as CFArray
            let locations = stops.map(\.0)
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) else { return }
            let center = CGPoint(x: size / 2, y: size / 2)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: size / 2, options: [])
        }

        private static func render(size: CGFloat, draw: (CGContext, CGFloat) -> Void) -> CGImage {
            let pixels = Int(size * 2)
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.scaleBy(x: 2, y: 2)
            draw(context, size)
            return context.makeImage()!
        }
    }
}

/// Small deterministic generator so the dust sprites look the same every launch.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
