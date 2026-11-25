import AppKit
import QuartzCore

/// Fabrique le masque du halo : opaque au bord de l'écran, transparent vers l'intérieur.
enum GlowMask {
    /// Contour du bord d'écran utilisé par le masque : le rectangle de l'écran, coins arrondis.
    static func screenOutline(size: CGSize, corner: CGFloat) -> CGPath {
        let bounds = CGRect(origin: .zero, size: size)
        let radius = max(0, min(corner, min(size.width, size.height) / 2 - 1))
        let path = CGMutablePath()
        path.addRoundedRect(in: bounds, cornerWidth: radius, cornerHeight: radius)
        return path
    }

    /// - Parameters:
    ///   - size: taille de l'écran en points.
    ///   - thickness: profondeur de la lueur depuis le bord.
    ///   - corner: rayon intérieur des coins.
    ///   - notch: contour de l'encoche au repos (repère « y vers le haut »), ou nil.
    static func make(size: CGSize, thickness: CGFloat, corner: CGFloat, notch: CGPath?) -> CGImage? {
        // Le masque est flou par nature : moitié de résolution, quatre fois moins de mémoire.
        let scale: CGFloat = 0.5
        let width = max(2, Int(size.width * scale))
        let height = max(2, Int(size.height * scale))
        guard size.width > 4, size.height > 4,
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.scaleBy(x: scale, y: scale)

        let bounds = CGRect(origin: .zero, size: size)
        let edge = screenOutline(size: size, corner: corner)
        let outline = CGMutablePath()
        outline.addPath(edge)
        if let notch {
            // Contour exact de l'encoche (coins compris) : la lueur l'épouse.
            outline.addPath(notch)
        }

        // Traits superposés de plus en plus larges, centrés sur le contour : l'opacité s'accumule
        // près du bord et s'éteint en douceur vers l'intérieur.
        context.setLineJoin(.round)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.09))
        let passes = 26
        for pass in 1...passes {
            let t = CGFloat(pass) / CGFloat(passes)
            context.setLineWidth(max(1, 2 * thickness * t * t))
            context.addPath(outline)
            context.strokePath()
        }

        // Les traits ne couvrent qu'une bande autour du contour arrondi. Entre l'arc et le vrai coin
        // de l'écran il restait un triangle sombre dès que le rayon dépassait celui de la dalle :
        // on le remplit, pour que la lueur touche toujours le bord réel, quel que soit le rayon.
        let corners = CGMutablePath()
        corners.addRect(bounds)
        corners.addPath(edge)
        context.addPath(corners)
        context.setFillColor(CGColor(gray: 1, alpha: 0.92))
        context.fillPath(using: .evenOdd)
        return context.makeImage()
    }
}

/// Le halo lui-même : uniquement des calques Core Animation, composés par le GPU.
/// L'app ne redessine rien image par image ; elle ne fait que changer des opacités.
final class GlowView: NSView {
    private let baseBox = CALayer()        // lueur de fond
    private let bloomBox = CALayer()       // lueur large, pilotée par les graves et les battements
    private let alertLayer = CALayer()     // couleur unie pour les alertes des agents
    private let baseSpin = CALayer()
    private let bloomSpin = CALayer()
    private let baseGradient = CAGradientLayer()
    private let bloomGradient = CAGradientLayer()
    private let baseMask = CALayer()
    private let bloomMask = CALayer()
    private let alertMask = CALayer()
    private let diagnostic = CAShapeLayer()  // contour exact, en rouge (mode diagnostic)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let root = CALayer()
        layer = root
        wantsLayer = true

        for gradient in [baseGradient, bloomGradient] {
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
        }
        for mask in [baseMask, bloomMask, alertMask] {
            mask.contentsGravity = .resize
        }

        baseSpin.addSublayer(baseGradient)
        bloomSpin.addSublayer(bloomGradient)
        baseBox.addSublayer(baseSpin)
        bloomBox.addSublayer(bloomSpin)
        baseBox.mask = baseMask
        bloomBox.mask = bloomMask
        alertLayer.mask = alertMask

        baseBox.opacity = 0
        bloomBox.opacity = 0
        alertLayer.opacity = 0

        root.addSublayer(baseBox)
        root.addSublayer(bloomBox)
        root.addSublayer(alertLayer)

        diagnostic.fillColor = nil
        diagnostic.strokeColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        diagnostic.lineWidth = 1
        diagnostic.isHidden = true
        root.addSublayer(diagnostic)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) n'est pas utilisé")
    }

    // MARK: Géométrie

    func configure(size: CGSize, thickness: CGFloat, corner: CGFloat, notch: CGPath?, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let bounds = CGRect(origin: .zero, size: size)
        let side = ceil(hypot(size.width, size.height))
        let square = CGRect(x: 0, y: 0, width: side, height: side)

        for box in [baseBox, bloomBox, alertLayer] {
            box.frame = bounds
        }
        for mask in [baseMask, bloomMask, alertMask] {
            mask.frame = bounds
        }
        for spin in [baseSpin, bloomSpin] {
            spin.bounds = square
            spin.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        for gradient in [baseGradient, bloomGradient] {
            gradient.frame = square
        }

        let thin = GlowMask.make(size: size, thickness: thickness, corner: corner, notch: notch)
        let wide = GlowMask.make(size: size, thickness: thickness * 2.2, corner: corner, notch: notch)
        baseMask.contents = thin
        bloomMask.contents = wide
        alertMask.contents = wide

        // Tracé de diagnostic : le contour utilisé par le masque, rentré d'un demi-point pour que
        // le trait de 1 px reste entièrement à l'écran.
        let traced = CGMutablePath()
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = max(0, min(corner, min(inset.width, inset.height) / 2 - 1))
        traced.addRoundedRect(in: inset, cornerWidth: radius, cornerHeight: radius)
        if let notch {
            traced.addPath(notch)
        }
        diagnostic.frame = bounds
        diagnostic.contentsScale = scale
        diagnostic.path = traced

        CATransaction.commit()
    }

    func setDiagnostics(_ enabled: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        diagnostic.isHidden = !enabled
        CATransaction.commit()
    }

    // MARK: Couleurs

    /// `ratio` = part de la première couleur sur le tour de l'écran (0,15 à 0,85).
    func setColors(_ first: CGColor, _ second: CGColor, ratio: CGFloat, duration: CFTimeInterval) {
        let blend: CGFloat = 0.12
        let share = min(max(ratio, 0.15), 0.85)
        let colors: [CGColor] = [first, first, second, second, first]
        let locations: [NSNumber] = [
            0,
            NSNumber(value: Double(max(0.02, share - blend))),
            NSNumber(value: Double(share)),
            NSNumber(value: Double(1 - blend)),
            1
        ]

        // Rotation en pause = horloge des calques enfants figée : un fondu n'avancerait pas.
        let frozen = baseSpin.speed == 0

        for gradient in [baseGradient, bloomGradient] {
            if duration > 0, !frozen, let from = gradient.presentation()?.colors ?? gradient.colors {
                let animation = CABasicAnimation(keyPath: "colors")
                animation.fromValue = from
                animation.toValue = colors
                animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                gradient.add(animation, forKey: "colors")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.colors = colors
            gradient.locations = locations
            CATransaction.commit()
        }
    }

    // MARK: Niveaux

    /// Opacité des deux lueurs. `duration` > 0 = fondu ; 0 = immédiat (suivi audio).
    func setLevels(base: Float, bloom: Float, duration: CFTimeInterval = 0) {
        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
        } else {
            CATransaction.setDisableActions(true)
        }
        baseBox.opacity = min(max(base, 0), 1)
        bloomBox.opacity = min(max(bloom, 0), 1)
        CATransaction.commit()
    }

    /// Respiration lente au repos, entièrement gérée par Core Animation.
    func startBreathing(low: Float, high: Float) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = low
        animation.toValue = high
        animation.duration = 3.4
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        baseBox.add(animation, forKey: "breathe")
    }

    func stopBreathing() {
        baseBox.removeAnimation(forKey: "breathe")
    }

    // MARK: Dérive (rotation lente du dégradé)

    func setDrift(_ active: Bool) {
        if active {
            for spin in [baseSpin, bloomSpin] {
                if spin.animation(forKey: "drift") == nil {
                    let animation = CABasicAnimation(keyPath: "transform.rotation.z")
                    animation.fromValue = 0
                    animation.toValue = Double.pi * 2
                    animation.duration = 48
                    animation.repeatCount = .infinity
                    animation.isRemovedOnCompletion = false
                    spin.add(animation, forKey: "drift")
                }
                resume(spin)
            }
        } else {
            for spin in [baseSpin, bloomSpin] {
                pause(spin)
            }
        }
    }

    /// Retire la rotation et remet le dégradé droit.
    func removeDrift() {
        for spin in [baseSpin, bloomSpin] {
            spin.removeAnimation(forKey: "drift")
            spin.speed = 1
            spin.timeOffset = 0
            spin.beginTime = 0
        }
    }

    private func pause(_ layer: CALayer) {
        guard layer.speed != 0 else { return }
        let pausedAt = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = pausedAt
    }

    private func resume(_ layer: CALayer) {
        guard layer.speed == 0 else { return }
        let pausedAt = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        let elapsed = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
        layer.beginTime = elapsed
    }

    // MARK: Alertes des agents

    /// Pulsation continue (validation en attente).
    func startAlert(color: CGColor) {
        alertLayer.backgroundColor = color
        guard alertLayer.animation(forKey: "pulse") == nil else { return }
        alertLayer.removeAnimation(forKey: "flash")
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.12
        animation.toValue = 0.95
        animation.duration = 0.75
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        alertLayer.add(animation, forKey: "pulse")
    }

    func stopAlert() {
        alertLayer.removeAnimation(forKey: "pulse")
    }

    /// Éclat bref (tâche terminée, erreur). Ignoré pendant une pulsation.
    func flash(color: CGColor, peak: Float = 0.9, duration: CFTimeInterval = 1.6) {
        guard alertLayer.animation(forKey: "pulse") == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        alertLayer.backgroundColor = color
        CATransaction.commit()
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, peak, 0]
        animation.keyTimes = [0, 0.22, 1]
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        alertLayer.add(animation, forKey: "flash")
    }
}
