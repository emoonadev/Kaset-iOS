import SwiftUI

/// Animated "now playing" bars, like kaset's `EqualizerView`.
///
/// The bars are Core Animation layers with repeating animations, so the render server draws
/// every frame; a SwiftUI `repeatForever` animation would re-render the whole list row view
/// tree on every display refresh while the playing row is on screen.
struct EqualizerView {
    var isAnimating: Bool
    var barCount = 4
    var spacing: CGFloat = 2
    var barWidth: CGFloat = 3
    var color: Color = .brand

    fileprivate func update(_ view: EqualizerBarsView, environment: EnvironmentValues) {
        view.configure(
            isAnimating: self.isAnimating && !environment.accessibilityReduceMotion,
            barCount: self.barCount, spacing: self.spacing, barWidth: self.barWidth,
            color: PlatformColor(self.color)
        )
    }

    fileprivate func size(for proposal: ProposedViewSize) -> CGSize {
        let count = CGFloat(self.barCount)
        return CGSize(
            width: count * self.barWidth + max(count - 1, 0) * self.spacing,
            height: proposal.height ?? 14
        )
    }
}

#if os(iOS)
extension EqualizerView: UIViewRepresentable {
    func makeUIView(context _: Context) -> EqualizerBarsView { EqualizerBarsView() }

    func updateUIView(_ view: EqualizerBarsView, context: Context) {
        self.update(view, environment: context.environment)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView _: EqualizerBarsView, context _: Context) -> CGSize? {
        self.size(for: proposal)
    }
}
#else
extension EqualizerView: NSViewRepresentable {
    func makeNSView(context _: Context) -> EqualizerBarsView { EqualizerBarsView() }

    func updateNSView(_ view: EqualizerBarsView, context: Context) {
        self.update(view, environment: context.environment)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: EqualizerBarsView, context _: Context) -> CGSize? {
        self.size(for: proposal)
    }
}
#endif

final class EqualizerBarsView: PlatformView {
    #if os(macOS)
    /// Top-left origin like UIKit, so the bar geometry below is shared.
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        self.layoutBars()
    }

    private func setNeedsLayout() { self.needsLayout = true }
    private func layoutIfNeeded() { self.layoutSubtreeIfNeeded() }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        self.layoutBars()
    }
    #endif

    private var bars: [CALayer] = []
    private var isAnimating = false
    private var barCount = 0
    private var barWidth: CGFloat = 3
    private var spacing: CGFloat = 2

    /// Per-bar rhythm so the bars do not move in unison.
    private static let rhythm: [(duration: CFTimeInterval, low: CGFloat, high: CGFloat)] = [
        (0.42, 0.18, 0.95), (0.55, 0.30, 0.80), (0.36, 0.15, 1.0), (0.62, 0.25, 0.75),
    ]

    fileprivate func configure(isAnimating: Bool, barCount: Int, spacing: CGFloat, barWidth: CGFloat, color: PlatformColor) {
        if barCount != self.barCount {
            self.bars.forEach { $0.removeFromSuperlayer() }
            self.bars = (0 ..< barCount).map { _ in
                let layer = CALayer()
                layer.cornerRadius = barWidth / 2
                self.hostLayer?.addSublayer(layer)
                return layer
            }
            self.barCount = barCount
        }
        self.spacing = spacing
        self.barWidth = barWidth
        for bar in self.bars {
            bar.backgroundColor = color.cgColor
            bar.cornerRadius = barWidth / 2
        }
        self.isAnimating = isAnimating
        self.setNeedsLayout()
        self.layoutIfNeeded()
        self.applyAnimation()
    }

    private var hostLayer: CALayer? { self.layer }

    private func layoutBars() {
        let height = self.bounds.height
        for (index, bar) in self.bars.enumerated() {
            let x = CGFloat(index) * (self.barWidth + self.spacing)
            let fraction = self.isAnimating ? Self.rhythm[index % Self.rhythm.count].low : 0.55
            bar.removeAllAnimations()
            // Bars grow from the bottom edge; `anchorPoint` at the bottom keeps that simple.
            bar.anchorPoint = CGPoint(x: 0.5, y: 1)
            bar.bounds = CGRect(x: 0, y: 0, width: self.barWidth, height: height * fraction)
            bar.position = CGPoint(x: x + self.barWidth / 2, y: height)
        }
        self.applyAnimation()
    }

    private func applyAnimation() {
        let height = self.bounds.height
        guard height > 0 else { return }
        for (index, bar) in self.bars.enumerated() {
            bar.removeAnimation(forKey: "eq")
            guard self.isAnimating else { continue }
            let profile = Self.rhythm[index % Self.rhythm.count]
            let animation = CABasicAnimation(keyPath: "bounds.size.height")
            animation.fromValue = height * profile.low
            animation.toValue = height * profile.high
            animation.duration = profile.duration
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timeOffset = Double(index) * 0.13
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(animation, forKey: "eq")
        }
    }
}
