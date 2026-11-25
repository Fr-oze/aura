import SwiftUI
import AppKit
import QuartzCore

/// Petits indicateurs animés en continu (égaliseur, points d'activité).
/// Ils sont animés par Core Animation, dans le serveur de rendu : l'app ne recalcule rien
/// image par image, contrairement à une animation SwiftUI répétée à l'infini.
final class IndicatorNSView: NSView {
    enum Style {
        case bars, dots
    }

    private let style: Style
    private var marks: [CALayer] = []
    private var color = CGColor(gray: 1, alpha: 1)
    private var active = false
    private var laidOutSize = CGSize.zero

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        let root = CALayer()
        layer = root
        wantsLayer = true
        let count = style == .bars ? 4 : 3
        for _ in 0..<count {
            let mark = CALayer()
            root.addSublayer(mark)
            marks.append(mark)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) n'est pas utilisé")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize != laidOutSize {
            laidOutSize = newSize
            arrange()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Les animations sont perdues quand la vue quitte une fenêtre : on les repose.
        arrange()
    }

    func configure(color: CGColor, active: Bool) {
        guard color != self.color || active != self.active else { return }
        self.color = color
        self.active = active
        arrange()
    }

    private func arrange() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let count = CGFloat(marks.count)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, mark) in marks.enumerated() {
            mark.removeAllAnimations()
            mark.backgroundColor = color
            let step = CGFloat(index)

            switch style {
            case .bars:
                let width: CGFloat = 2.5
                let gap = count > 1 ? (size.width - width * count) / (count - 1) : 0
                mark.anchorPoint = CGPoint(x: 0.5, y: 0)
                mark.bounds = CGRect(x: 0, y: 0, width: width, height: size.height)
                mark.position = CGPoint(x: width / 2 + step * (width + gap), y: 0)
                mark.cornerRadius = width / 2
                mark.opacity = 1
                mark.transform = CATransform3DMakeScale(1, active ? 0.6 : 0.25, 1)
                if active && window != nil {
                    let animation = CABasicAnimation(keyPath: "transform.scale.y")
                    animation.fromValue = 0.22
                    animation.toValue = 1.0
                    animation.duration = [0.42, 0.31, 0.5, 0.36][index % 4]
                    animation.autoreverses = true
                    animation.repeatCount = .infinity
                    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    animation.timeOffset = Double(index) * 0.17
                    mark.add(animation, forKey: "bounce")
                }
            case .dots:
                let side = min(5, size.height)
                let gap = count > 1 ? (size.width - side * count) / (count - 1) : 0
                mark.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                mark.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                mark.position = CGPoint(x: side / 2 + step * (side + gap), y: size.height / 2)
                mark.cornerRadius = side / 2
                mark.transform = CATransform3DIdentity
                mark.opacity = active ? 1 : 0.45
                if active && window != nil {
                    let animation = CABasicAnimation(keyPath: "opacity")
                    animation.fromValue = 0.25
                    animation.toValue = 1.0
                    animation.duration = 0.55
                    animation.autoreverses = true
                    animation.repeatCount = .infinity
                    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    animation.timeOffset = Double(index) * 0.18
                    mark.add(animation, forKey: "pulse")
                }
            }
        }
        CATransaction.commit()
    }
}

/// Mini égaliseur : quatre barres qui dansent tant que la musique joue.
@MainActor
struct EqualizerBars: NSViewRepresentable {
    var color: Color
    var active: Bool

    func makeNSView(context: Context) -> IndicatorNSView {
        let view = IndicatorNSView(style: .bars)
        view.configure(color: NSColor(color).cgColor, active: active)
        return view
    }

    func updateNSView(_ nsView: IndicatorNSView, context: Context) {
        nsView.configure(color: NSColor(color).cgColor, active: active)
    }
}

/// Trois points qui respirent : l'agent travaille.
@MainActor
struct ActivityDots: NSViewRepresentable {
    var color: Color

    func makeNSView(context: Context) -> IndicatorNSView {
        let view = IndicatorNSView(style: .dots)
        view.configure(color: NSColor(color).cgColor, active: true)
        return view
    }

    func updateNSView(_ nsView: IndicatorNSView, context: Context) {
        nsView.configure(color: NSColor(color).cgColor, active: true)
    }
}
