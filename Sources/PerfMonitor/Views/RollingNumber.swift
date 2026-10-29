import AppKit
import QuartzCore
import SwiftUI

/// Large number whose changed digits roll in. The animation is a Core Animation layer animation,
/// so it runs in the render server: SwiftUI's numericText transition redrew the card on every
/// frame and cost ~19% CPU for six numbers.
struct RollingNumber: NSViewRepresentable {
    let text: String
    let value: Double
    var size: CGFloat = 34
    var color: Color = .primary

    func makeNSView(context: Context) -> RollingNumberView { RollingNumberView() }

    func updateNSView(_ view: RollingNumberView, context: Context) {
        view.update(text: text, value: value, size: size, color: NSColor(color))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RollingNumberView, context: Context) -> CGSize? {
        nsView.measure(text: text, size: size)
    }
}

final class RollingNumberView: NSView {
    private var chars: [(char: Character, layer: CATextLayer)] = []
    private var lastValue: Double?
    private var font: NSFont?
    private var fontSize: CGFloat = 0
    private var color = NSColor.labelColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func makeFont(_ size: CGFloat) -> NSFont {
        if let font, fontSize == size { return font }
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        var desc = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        desc = desc.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        let f = NSFont(descriptor: desc, size: size) ?? base
        font = f
        widths = [:]
        fontSize = size
        return f
    }

    /// Glyph widths per font size; measuring text on every update showed up in profiles.
    private var widths: [Character: CGFloat] = [:]

    private func width(of c: Character, _ f: NSFont) -> CGFloat {
        if let w = widths[c] { return w }
        let w = ceil(NSAttributedString(string: String(c), attributes: [.font: f]).size().width)
        widths[c] = w
        return w
    }

    func measure(text: String, size: CGFloat) -> CGSize {
        let f = makeFont(size)
        let w = text.reduce(0) { $0 + width(of: $1, f) }
        return CGSize(width: w, height: ceil(f.ascender - f.descender))
    }

    func update(text: String, value: Double, size: CGFloat, color: NSColor) {
        guard let root = layer else { return }
        let f = makeFont(size)
        let scale = window?.backingScaleFactor ?? 2
        let height = ceil(f.ascender - f.descender)
        // Resolve dynamic colours for the current appearance.
        var cg = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        let colorChanged = color != self.color
        self.color = color

        let newChars = Array(text)
        let up = (lastValue.map { value >= $0 } ?? true)
        let animate = lastValue != nil && window != nil
        lastValue = value

        // Align old and new strings from the right, where the digits that change most live.
        let oldCount = chars.count, newCount = newChars.count
        var kept: [Int: (Character, CATextLayer)] = [:]   // new index → reused layer
        var leaving: [CATextLayer] = []
        for (i, entry) in chars.enumerated() {
            let fromRight = oldCount - 1 - i
            let j = newCount - 1 - fromRight
            if j >= 0, j < newCount, newChars[j] == entry.char {
                kept[j] = entry
            } else {
                leaving.append(entry.layer)
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var x: CGFloat = 0
        var next: [(Character, CATextLayer)] = []
        var entering: [CATextLayer] = []
        for (j, c) in newChars.enumerated() {
            let w = width(of: c, f)
            let frame = CGRect(x: x, y: 0, width: w, height: height)
            if let (_, l) = kept[j] {
                l.frame = frame
                if colorChanged { l.foregroundColor = cg }
                next.append((c, l))
            } else {
                let l = CATextLayer()
                l.contentsScale = scale
                l.string = NSAttributedString(string: String(c), attributes: [.font: f, .foregroundColor: color])
                l.foregroundColor = cg
                l.alignmentMode = .center
                l.frame = frame
                root.addSublayer(l)
                next.append((c, l))
                entering.append(l)
            }
            x += w
        }
        if colorChanged {
            for (c, l) in next { l.string = NSAttributedString(string: String(c), attributes: [.font: f, .foregroundColor: color]) }
        }
        chars = next
        CATransaction.commit()

        guard animate else {
            leaving.forEach { $0.removeFromSuperlayer() }
            return
        }
        let offset = height * 0.7 * (up ? 1 : -1)
        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        for l in entering {
            l.add(Self.slide(from: offset, to: 0, fadeIn: true, timing: timing), forKey: "roll")
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { leaving.forEach { $0.removeFromSuperlayer() } }
        for l in leaving {
            l.add(Self.slide(from: 0, to: -offset, fadeIn: false, timing: timing), forKey: "roll")
            l.opacity = 0
        }
        CATransaction.commit()
    }

    private static func slide(from: CGFloat, to: CGFloat, fadeIn: Bool, timing: CAMediaTimingFunction) -> CAAnimation {
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = from
        move.toValue = to
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fadeIn ? 0 : 1
        fade.toValue = fadeIn ? 1 : 0
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.35
        group.timingFunction = timing
        group.fillMode = .forwards
        group.isRemovedOnCompletion = fadeIn   // leaving layers stay hidden until removed
        return group
    }
}
