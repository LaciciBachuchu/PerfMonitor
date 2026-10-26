import SwiftUI

struct Card<Content: View, Accessory: View>: View {
    let title: String
    let icon: String
    var hero: String?
    var heroColor: Color = .primary
    var heroValue: Double = 0
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, icon: String, hero: String? = nil, heroColor: Color = .primary, heroValue: Double = 0,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.hero = hero
        self.heroColor = heroColor
        self.heroValue = heroValue
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Label(title, systemImage: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                accessory
                if let hero {
                    RollingNumber(text: hero, value: heroValue, size: 34, color: heroColor)
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }
}

extension View {
    /// Glass buttons on macOS 26+, the default bordered style before that.
    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// Liquid Glass on macOS 26+, frosted material before that.
    @ViewBuilder
    func cardBackground(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(tint.map { .regular.tint($0.opacity(0.18)) } ?? .regular,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.08)))
        }
    }
}

struct Metric: View {
    let label: String
    let value: String
    var color: Color = .primary
    var sub: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).foregroundStyle(color)
                .monospacedDigit().lineLimit(1)
            if let sub { Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Readings that wrap onto another line instead of truncating when the card is narrow.
struct MetricRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8, alignment: .topLeading)], alignment: .leading, spacing: 8) {
            content
        }
    }
}

/// Small caption line of "label value" pairs.
struct InfoLine: View {
    let items: [String]
    var body: some View {
        Text(items.joined(separator: "  ·  ")).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
}

struct Bar: View {
    let value: Double   // 0...1
    var tint: Color = .accentColor
    var height: CGFloat = 5

    var body: some View {
        Canvas { ctx, size in
            let r = size.height / 2
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: r), with: .color(.secondary.opacity(0.18)))
            let w = max(0, min(1, value)) * size.width
            if w > 0 { ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: size.height), cornerRadius: r), with: .color(tint)) }
        }
        .frame(height: height)
    }
}

struct LabeledBar: View {
    let label: String
    let value: Double
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Bar(value: value, tint: tint, height: 6)
            Text(text).font(.caption.monospacedDigit()).frame(width: 104, alignment: .trailing)
        }
    }
}

/// One wide bar split into coloured segments, with the remainder shown as free.
struct StackedBar: View {
    struct Segment {
        let label: String
        let value: Double
        let color: Color
    }

    let total: Double
    let segments: [Segment]
    var height: CGFloat = 16

    var body: some View {
        let used = segments.reduce(0) { $0 + $1.value }
        VStack(alignment: .leading, spacing: 3) {
            Canvas { ctx, size in
                let clip = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
                ctx.clip(to: clip)
                ctx.fill(clip, with: .color(.secondary.opacity(0.18)))
                var x: CGFloat = 0
                for seg in segments {
                    let w = size.width * CGFloat(seg.value / max(total, 1))
                    ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(seg.color))
                    x += w
                }
            }
            .frame(height: height)
            HStack(spacing: 10) {
                ForEach(segments.indices, id: \.self) { i in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1.5).fill(segments[i].color).frame(width: 7, height: 7)
                        Text("\(segments[i].label) \(ByteFormat.short(segments[i].value))")
                    }
                }
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.25)).frame(width: 7, height: 7)
                    Text("空闲 \(ByteFormat.short(max(0, total - used)))")
                }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// Multi-series line chart drawn in one Canvas pass: far cheaper than Swift Charts
/// for a 2-second refresh, and compact. Values outside `range` are clamped.
struct Sparkline: View {
    struct Series {
        let name: String
        let color: Color
        let values: [Double?]
        var fill = false
    }

    let series: [Series]
    var range: ClosedRange<Double>? = nil
    var unit = ""
    var height: CGFloat = 56
    var stacked = false
    /// Grow to fill spare vertical space in the card.
    var flexible = true

    var body: some View {
        let all = series.flatMap { $0.values.compactMap { $0 } }
        let stackTop = stacked ? (0..<(series.first?.values.count ?? 0)).map { i in series.reduce(0) { $0 + ($1.values[i] ?? 0) } }.max() ?? 0 : 0
        let lo = range?.lowerBound ?? (stacked ? 0 : max(0, (all.min() ?? 0) - 2))
        let hi = range?.upperBound ?? max(stacked ? stackTop : (all.max() ?? 1), lo + 1) * 1.05
        VStack(alignment: .leading, spacing: 2) {
            Canvas { ctx, size in
                let n = max(series.first?.values.count ?? 0, 2)
                func pt(_ i: Int, _ v: Double) -> CGPoint {
                    CGPoint(x: size.width * CGFloat(i) / CGFloat(n - 1),
                            y: size.height * (1 - CGFloat((min(max(v, lo), hi) - lo) / (hi - lo))))
                }
                for f in [0.5] {   // single midline as a scale reference
                    var g = Path(); g.move(to: CGPoint(x: 0, y: size.height * f)); g.addLine(to: CGPoint(x: size.width, y: size.height * f))
                    ctx.stroke(g, with: .color(.secondary.opacity(0.15)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                }
                var base = [Double](repeating: 0, count: n)
                for s in series {
                    var line = Path(), area = Path()
                    var started = false
                    var prevPt = CGPoint.zero
                    var top = base
                    for (i, v) in s.values.enumerated() {
                        guard let v else { continue }
                        top[i] = (stacked ? base[i] : 0) + v
                        let p = pt(i, top[i])
                        if !started {
                            line.move(to: p); area.move(to: pt(i, stacked ? base[i] : lo)); area.addLine(to: p); started = true
                        } else if stacked {
                            line.addLine(to: p); area.addLine(to: p)
                        } else {
                            // Smooth curve: quadratic segments through the midpoints.
                            let mid = CGPoint(x: (prevPt.x + p.x) / 2, y: (prevPt.y + p.y) / 2)
                            line.addQuadCurve(to: mid, control: prevPt)
                            area.addQuadCurve(to: mid, control: prevPt)
                        }
                        prevPt = p
                    }
                    guard started else { continue }
                    if !stacked { line.addLine(to: prevPt); area.addLine(to: prevPt) }
                    if s.fill || stacked {
                        for i in stride(from: s.values.count - 1, through: 0, by: -1) where s.values[i] != nil {
                            area.addLine(to: pt(i, stacked ? base[i] : lo))
                        }
                        area.closeSubpath()
                        ctx.fill(area, with: .color(s.color.opacity(stacked ? 0.55 : 0.18)))
                    }
                    ctx.stroke(line, with: .color(s.color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    if stacked { base = top }
                }
            }
            .frame(minHeight: height, maxHeight: flexible ? .infinity : height)
            .overlay(alignment: .topTrailing) {
                Text(String(format: "%.0f%@", hi, unit)).font(.system(size: 9)).foregroundStyle(.tertiary).padding(.trailing, 1)
            }
            HStack(spacing: 8) {
                ForEach(series.indices, id: \.self) { i in
                    HStack(spacing: 3) {
                        Circle().fill(series[i].color).frame(width: 5, height: 5)
                        Text(series[i].name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

enum Palette {
    static func temp(_ c: Double?) -> Color {
        guard let c else { return .secondary }
        switch c {
        case ..<60: return .green
        case ..<80: return .yellow
        case ..<95: return .orange
        default: return .red
        }
    }

    static func load(_ v: Double) -> Color {
        switch v {
        case ..<0.5: return .green
        case ..<0.8: return .yellow
        default: return .red
        }
    }

    static func severity(_ s: Finding.Severity) -> Color {
        switch s {
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }

    static func thermal(_ t: SystemSampler.ThermalPressure) -> Color {
        switch t {
        case .nominal: return .green
        case .moderate: return .yellow
        case .heavy: return .orange
        default: return .red
        }
    }
}

enum Fmt {
    static func temp(_ c: Double?) -> String { c.map { String(format: "%.0f°C", $0) } ?? "—" }
    static func watts(_ w: Double?) -> String {
        guard let w else { return "—" }
        return w < 10 ? String(format: "%.2f W", w) : String(format: "%.1f W", w)
    }
    static func procWatts(_ p: ProcessStat) -> String {
        guard let w = p.powerW else { return "—" }
        return (p.powerEstimated ? "≈" : "") + String(format: "%.2f W", w)
    }
    /// CPU-time style: "1:02:03.45" / "2:03.45" / "3.45".
    static func duration(_ sec: Double) -> String {
        let h = Int(sec) / 3600, m = Int(sec) % 3600 / 60
        let s = sec - Double(h * 3600 + m * 60)
        if h > 0 { return String(format: "%d:%02d:%05.2f", h, m, s) }
        if m > 0 { return String(format: "%d:%05.2f", m, s) }
        return String(format: "%.2f", s)
    }

    static func energy(_ joules: Double) -> String {
        joules >= 3600 ? String(format: "%.2f Wh", joules / 3600) : String(format: joules < 10 ? "%.2f J" : "%.0f J", joules)
    }

    private static let sameDay: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    private static let otherDay: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"; return f }()

    static func startTime(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? sameDay.string(from: d) : otherDay.string(from: d)
    }

    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    static func mhz(_ v: Double) -> String { v >= 1000 ? String(format: "%.2f GHz", v / 1000) : String(format: "%.0f MHz", v) }
}
