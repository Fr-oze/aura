import AppKit
import QuartzCore

/// Contour de la forme d'encoche. Un seul constructeur pour tout : la forme noire, le masque
/// du contenu, le halo d'encoche, le masque du halo d'écran et le tracé de diagnostic.
enum NotchShape {
    /// Constante d'approximation d'un quart de cercle par une courbe de Bézier.
    private static let kappa: CGFloat = 0.5523

    /// Contour fermé, en repère « y vers le haut » (origine en bas à gauche).
    ///
    /// - Parameters:
    ///   - centerX: abscisse du centre de l'encoche.
    ///   - top: ordonnée du bord haut de l'écran.
    ///   - overshoot: dépassement au-dessus du bord haut, pour que rien ne se voie à la jonction.
    ///
    /// Le tracé a toujours la même suite d'éléments (4 courbes, 6 droites) : Core Animation
    /// peut donc interpoler d'une forme à l'autre, quelle que soit la taille.
    static func path(centerX: CGFloat, top: CGFloat, layout: NotchLayout, overshoot: CGFloat = 40) -> CGPath {
        let path = CGMutablePath()
        let ends = trace(into: path, centerX: centerX, top: top, layout: layout)
        // Fermeture au-dessus du bord de l'écran.
        path.addLine(to: CGPoint(x: ends.right, y: top + overshoot))
        path.addLine(to: CGPoint(x: ends.left, y: top + overshoot))
        path.closeSubpath()
        return path
    }

    /// Même contour, laissé ouvert : seulement la partie visible, du bord gauche au bord droit.
    /// Il est symétrique, donc son milieu (fraction 0,5) tombe au centre du bas de la forme.
    /// Sert à l'onde qui part de l'encoche et longe la forme.
    static func contour(centerX: CGFloat, top: CGFloat, layout: NotchLayout) -> CGPath {
        let path = CGMutablePath()
        _ = trace(into: path, centerX: centerX, top: top, layout: layout)
        return path
    }

    /// Trace la partie visible du contour. Renvoie les abscisses de ses deux extrémités.
    private static func trace(into path: CGMutablePath, centerX: CGFloat, top: CGFloat,
                              layout: NotchLayout) -> (left: CGFloat, right: CGFloat) {
        let width = max(0, layout.width)
        let height = max(0, layout.height)
        let fillet = max(0, min(layout.topRadius, height / 2))
        let corner = max(0, min(layout.bottomRadius, min(height - fillet, width / 2)))
        let left = centerX - width / 2
        let right = centerX + width / 2
        let bottom = top - height
        let k = NotchShape.kappa

        // Coin concave gauche : du bord de l'écran vers le flanc de la forme.
        path.move(to: CGPoint(x: left - fillet, y: top))
        path.addCurve(to: CGPoint(x: left, y: top - fillet),
                      control1: CGPoint(x: left - fillet + k * fillet, y: top),
                      control2: CGPoint(x: left, y: top - fillet + k * fillet))
        // Flanc gauche puis coin arrondi bas gauche.
        path.addLine(to: CGPoint(x: left, y: bottom + corner))
        path.addCurve(to: CGPoint(x: left + corner, y: bottom),
                      control1: CGPoint(x: left, y: bottom + corner - k * corner),
                      control2: CGPoint(x: left + corner - k * corner, y: bottom))
        // Bas puis coin arrondi bas droit.
        path.addLine(to: CGPoint(x: right - corner, y: bottom))
        path.addCurve(to: CGPoint(x: right, y: bottom + corner),
                      control1: CGPoint(x: right - corner + k * corner, y: bottom),
                      control2: CGPoint(x: right, y: bottom + corner - k * corner))
        // Flanc droit puis coin concave droit.
        path.addLine(to: CGPoint(x: right, y: top - fillet))
        path.addCurve(to: CGPoint(x: right + fillet, y: top),
                      control1: CGPoint(x: right, y: top - fillet + k * fillet),
                      control2: CGPoint(x: right + fillet - k * fillet, y: top))
        return (left - fillet, right + fillet)
    }

    /// Ressort commun à toutes les transformations de la forme.
    /// Équivaut à `.spring(response: 0.42, dampingFraction: 0.78)` côté SwiftUI :
    /// raideur = (2π / réponse)², amortissement = 4π × fraction / réponse.
    static func spring(keyPath: String) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = 224
        animation.damping = 23.3
        animation.initialVelocity = 0
        animation.duration = animation.settlingDuration
        return animation
    }
}
