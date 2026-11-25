import AppKit
import SwiftUI
import QuartzCore

/// Fenêtre de l'encoche : transparente, sans bordure, à cadre fixe, au-dessus de la barre de menus.
/// Elle ne prend jamais le focus d'elle-même (sauf clic pendant une validation, pour ↩ / esc).
final class NotchPanel: NSPanel {
    var allowsKey = false
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// On garde exactement le cadre demandé (collé au bord haut de l'écran).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Retour, Entrée
            onReturn?()
        case 53: // Échap
            onEscape?()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// Vue SwiftUI hébergée dans une fenêtre d'Aura.
/// Toujours ajoutée en sous-vue d'une vue AppKit à cadre fixe, jamais comme `contentView`,
/// avec `sizingOptions = []` : SwiftUI ne pilote donc jamais la taille de la fenêtre.
/// Les marges de sécurité sont figées à zéro : leur invalidation pendant le layout relançait
/// une passe de contraintes et finissait en exception (« needs another Update Constraints pass »).
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

/// Rythme du halo d'encoche tant qu'un état dure.
enum GlowMode: String {
    /// Fixe : l'intensité porte l'information (volume, luminosité).
    case steady
    /// Respiration lente.
    case breathe
    /// Pulsation nette (validation, notification).
    case pulse
}

/// Calques de la forme : halo d'encoche dessous, forme noire dessus. Aucun dessin par image :
/// tout est composé par le serveur de rendu, l'app ne fait que poser des animations.
///
/// Tous les calques du halo sont des `CAShapeLayer` qui portent le même `path` que la forme noire.
/// La lueur est l'ombre de leur propre contenu (pas de `shadowPath`) : elle suit donc toujours
/// le contour affiché, y compris en pleine animation.
final class NotchLayerView: NSView {
    /// Apparition et extinction du halo.
    let glowGroup = CALayer()
    /// Respiration ou pulsation.
    let lifeGroup = CALayer()
    let wide = CAShapeLayer()
    let tight = CAShapeLayer()
    let rim = CAShapeLayer()
    /// Éclat bref du liseré (apparition, battement de la musique).
    let flash = CAShapeLayer()
    /// Onde qui part du centre et longe la forme, une moitié de chaque côté.
    let waveLeft = CAShapeLayer()
    let waveRight = CAShapeLayer()
    let shape = CAShapeLayer()

    static let wideRadius: CGFloat = 22
    static let tightRadius: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        layer = root
        wantsLayer = true

        // Deux lueurs (large et serrée) : une forme pleine, cachée sous la forme noire, dont seule
        // l'ombre colorée dépasse. Mises en cache tant que le contour ne bouge pas.
        let glows: [(CAShapeLayer, CGFloat)] = [(wide, NotchLayerView.wideRadius), (tight, NotchLayerView.tightRadius)]
        for (glow, radius) in glows {
            glow.strokeColor = nil
            glow.shadowOffset = .zero
            glow.shadowRadius = radius
            glow.shadowOpacity = 1
            glow.shouldRasterize = true
            glow.opacity = 0
        }
        rim.fillColor = nil
        rim.lineWidth = 2.4
        rim.lineJoin = .round
        rim.opacity = 0
        flash.fillColor = nil
        flash.lineWidth = 6
        flash.lineJoin = .round
        flash.opacity = 0
        // Au repos les ondes ne dessinent rien : leur segment a une longueur nulle.
        waveLeft.fillColor = nil
        waveLeft.lineWidth = 3.5
        waveLeft.lineCap = .round
        waveLeft.strokeStart = 0
        waveLeft.strokeEnd = 0
        waveRight.fillColor = nil
        waveRight.lineWidth = 3.5
        waveRight.lineCap = .round
        waveRight.strokeStart = 1
        waveRight.strokeEnd = 1
        lifeGroup.addSublayer(wide)
        lifeGroup.addSublayer(tight)
        lifeGroup.addSublayer(rim)
        glowGroup.opacity = 0
        glowGroup.addSublayer(lifeGroup)
        glowGroup.addSublayer(flash)
        glowGroup.addSublayer(waveLeft)
        glowGroup.addSublayer(waveRight)

        // Noir pur, sans bordure : la forme se confond avec l'encoche physique.
        shape.fillColor = CGColor(gray: 0, alpha: 1)
        shape.strokeColor = nil
        shape.lineWidth = 0

        root.addSublayer(glowGroup)
        root.addSublayer(shape)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) n'est pas utilisé")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Tracé rouge de 1 px du contour exact de la forme (mode diagnostic).
final class NotchOutlineView: NSView {
    let line = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        layer = root
        wantsLayer = true
        line.fillColor = nil
        line.strokeColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        line.lineWidth = 1
        line.isHidden = true
        root.addSublayer(line)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) n'est pas utilisé")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Vue racine de la fenêtre de l'encoche : une vue AppKit simple à cadre fixe.
/// Elle empile les calques de la forme, le contenu SwiftUI découpé par la même forme,
/// et le tracé de diagnostic. Les changements de forme passent par les `path` des calques,
/// jamais par le cadre de la fenêtre.
final class NotchSurfaceView: NSView {
    private let layers: NotchLayerView
    private let clip: NSView
    private let outline: NotchOutlineView
    private let contentMask = CAShapeLayer()
    private var centerX: CGFloat = 0
    private var current: NotchLayout?
    private var glowOn = false
    private var glowColorKey = ""
    private var glowMode = GlowMode.steady

    init(frame frameRect: NSRect, content: NSView) {
        let box = NSRect(origin: .zero, size: frameRect.size)
        layers = NotchLayerView(frame: box)
        clip = NSView(frame: box)
        outline = NotchOutlineView(frame: box)
        super.init(frame: frameRect)
        wantsLayer = true

        layers.autoresizingMask = [.width, .height]
        clip.autoresizingMask = [.width, .height]
        outline.autoresizingMask = [.width, .height]
        content.frame = box
        content.autoresizingMask = [.width, .height]

        // Le contenu est découpé par la forme elle-même : il se révèle au rythme du morphing.
        clip.wantsLayer = true
        contentMask.fillColor = CGColor(gray: 0, alpha: 1)
        clip.layer?.mask = contentMask
        clip.addSubview(content)

        addSubview(layers)
        addSubview(clip)
        addSubview(outline)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) n'est pas utilisé")
    }

    /// Calques qui portent le contour fermé : la forme noire, le masque du contenu, le tracé de
    /// diagnostic et tout le halo. Ils reçoivent toujours le même `CGPath`, en même temps.
    private var closedLayers: [CAShapeLayer] {
        [layers.shape, contentMask, outline.line, layers.wide, layers.tight, layers.rim, layers.flash]
    }

    /// Calques qui portent le contour ouvert (ondes).
    private var openLayers: [CAShapeLayer] {
        [layers.waveLeft, layers.waveRight]
    }

    /// À appeler après chaque placement de la fenêtre.
    /// `centerX` : abscisse du centre de l'encoche dans la fenêtre. `scale` : densité de l'écran.
    func relayout(centerX: CGFloat, scale: CGFloat) {
        self.centerX = centerX
        let box = CGRect(origin: .zero, size: bounds.size)
        var all: [CALayer] = [layers.glowGroup, layers.lifeGroup]
        for layer in closedLayers {
            all.append(layer)
        }
        for layer in openLayers {
            all.append(layer)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in all {
            layer.frame = box
            layer.contentsScale = scale
            layer.rasterizationScale = scale
        }
        CATransaction.commit()
        if let current {
            morph(to: current, animated: false)
        }
    }

    /// Transforme la forme. C'est le seul endroit où un contour est posé : la forme noire, le masque
    /// du contenu et tous les calques du halo reçoivent le même `CGPath`, le même ressort, le même
    /// point de départ (la forme réellement affichée) dans la même transaction, donc au même instant.
    func morph(to layout: NotchLayout, animated: Bool) {
        current = layout
        let top = bounds.maxY
        let path = NotchShape.path(centerX: centerX, top: top, layout: layout)
        let contour = NotchShape.contour(centerX: centerX, top: top, layout: layout)
        // Départ unique : la forme noire telle qu'elle est à l'écran, même en plein vol.
        let from = layers.shape.presentation()?.path ?? layers.shape.path
        let fromContour = layers.waveLeft.presentation()?.path ?? layers.waveLeft.path

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in closedLayers {
            layer.path = path
            if animated, let from {
                let animation = NotchShape.spring(keyPath: "path")
                animation.fromValue = from
                animation.toValue = path
                layer.add(animation, forKey: "morph")
            } else {
                layer.removeAnimation(forKey: "morph")
            }
        }
        for layer in openLayers {
            layer.path = contour
            if animated, let fromContour {
                let animation = NotchShape.spring(keyPath: "path")
                animation.fromValue = fromContour
                animation.toValue = contour
                layer.add(animation, forKey: "morph")
            } else {
                layer.removeAnimation(forKey: "morph")
            }
        }
        CATransaction.commit()
    }

    // MARK: Halo d'encoche

    /// Couleur, force et rythme du halo. `nil` l'éteint en fondu.
    /// `bloom` rejoue l'apparition (fondu et gonflement) : à passer quand la forme change d'état.
    func setGlow(color: CGColor?, intensity: Float, mode: GlowMode, bloom: Bool) {
        guard let color else {
            guard glowOn else { return }
            glowOn = false
            glowColorKey = ""
            let shown = layers.glowGroup.presentation()?.opacity ?? layers.glowGroup.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layers.glowGroup.opacity = 0
            CATransaction.commit()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shown
            fade.toValue = 0
            fade.duration = 0.45
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layers.glowGroup.add(fade, forKey: "appear")
            return
        }

        let wasOff = !glowOn
        let colorKey = "\(color.components ?? [])"
        let colorChanged = colorKey != glowColorKey
        glowOn = true
        glowColorKey = colorKey

        // Couleur et intensité. Éteint : posées d'un coup, c'est l'apparition qui fait le fondu.
        let strength = min(max(intensity, 0), 1.4)
        CATransaction.begin()
        if wasOff {
            CATransaction.setDisableActions(true)
        } else {
            CATransaction.setAnimationDuration(0.22)
        }
        if colorChanged {
            let bright = NotchSurfaceView.lighten(color)
            layers.wide.fillColor = color
            layers.wide.shadowColor = color
            layers.tight.fillColor = color
            layers.tight.shadowColor = color
            layers.rim.strokeColor = color
            layers.flash.strokeColor = bright
            layers.waveLeft.strokeColor = bright
            layers.waveRight.strokeColor = bright
        }
        layers.wide.opacity = min(1, 0.85 * strength)
        layers.tight.opacity = min(1, strength)
        layers.rim.opacity = min(1, 0.95 * strength)
        CATransaction.commit()

        // Rythme tant que l'état dure.
        if wasOff || mode != glowMode || layers.lifeGroup.animation(forKey: "life") == nil && mode != .steady {
            glowMode = mode
            layers.lifeGroup.removeAnimation(forKey: "life")
            if mode != .steady {
                let life = CABasicAnimation(keyPath: "opacity")
                life.fromValue = 1.0
                life.toValue = mode == .pulse ? 0.2 : 0.55
                life.duration = mode == .pulse ? 0.55 : 2.4
                life.autoreverses = true
                life.repeatCount = .infinity
                life.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layers.lifeGroup.add(life, forKey: "life")
            }
        }

        // Apparition : fondu, gonflement de la lueur large, éclat du liseré.
        if wasOff || bloom {
            let shown = layers.glowGroup.presentation()?.opacity ?? layers.glowGroup.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layers.glowGroup.opacity = 1
            CATransaction.commit()

            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = wasOff ? 0 : shown
            appear.toValue = 1
            appear.duration = 0.3
            appear.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layers.glowGroup.add(appear, forKey: "appear")

            let swell = CAKeyframeAnimation(keyPath: "shadowRadius")
            swell.values = [NotchLayerView.tightRadius, NotchLayerView.wideRadius * 1.6, NotchLayerView.wideRadius]
            swell.keyTimes = [0, 0.4, 1]
            swell.duration = 0.62
            swell.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layers.wide.add(swell, forKey: "swell")

            flashRim(peak: 0.85, duration: 0.5)
        }
    }

    /// Onde rapide : deux traits clairs partent du centre du bas de la forme et longent le contour
    /// jusqu'au bord de l'écran, un de chaque côté. Jouée à chaque écho.
    func ripple() {
        guard glowOn else { return }
        let duration = 0.55
        let fast = CAMediaTimingFunction(name: .easeOut)
        let slow = CAMediaTimingFunction(name: .easeIn)

        // Côté gauche : la tête (début du trait) file vers 0, la queue (fin du trait) la rattrape.
        let leftHead = CABasicAnimation(keyPath: "strokeStart")
        leftHead.fromValue = 0.5
        leftHead.toValue = 0.0
        leftHead.duration = duration
        leftHead.timingFunction = fast
        let leftTail = CABasicAnimation(keyPath: "strokeEnd")
        leftTail.fromValue = 0.5
        leftTail.toValue = 0.0
        leftTail.duration = duration
        leftTail.timingFunction = slow
        layers.waveLeft.add(leftHead, forKey: "head")
        layers.waveLeft.add(leftTail, forKey: "tail")

        // Côté droit, en miroir.
        let rightHead = CABasicAnimation(keyPath: "strokeEnd")
        rightHead.fromValue = 0.5
        rightHead.toValue = 1.0
        rightHead.duration = duration
        rightHead.timingFunction = fast
        let rightTail = CABasicAnimation(keyPath: "strokeStart")
        rightTail.fromValue = 0.5
        rightTail.toValue = 1.0
        rightTail.duration = duration
        rightTail.timingFunction = slow
        layers.waveRight.add(rightHead, forKey: "head")
        layers.waveRight.add(rightTail, forKey: "tail")
    }

    /// Battement de la musique : le liseré s'allume un instant.
    func kick() {
        guard glowOn else { return }
        flashRim(peak: 0.7, duration: 0.3)
    }

    private func flashRim(peak: Float, duration: CFTimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [Float(0), peak, Float(0)]
        animation.keyTimes = [0, 0.25, 1]
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layers.flash.add(animation, forKey: "flash")
    }

    /// Même teinte, tirée vers le blanc : pour l'onde et l'éclat du liseré.
    private static func lighten(_ color: CGColor) -> CGColor {
        guard let parts = color.components, parts.count >= 3 else {
            return CGColor(gray: 1, alpha: 1)
        }
        let mix: CGFloat = 0.6
        return CGColor(srgbRed: parts[0] + (1 - parts[0]) * mix,
                       green: parts[1] + (1 - parts[1]) * mix,
                       blue: parts[2] + (1 - parts[2]) * mix,
                       alpha: 1)
    }

    func setDiagnostics(_ enabled: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.line.isHidden = !enabled
        CATransaction.commit()
    }
}
