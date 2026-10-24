import PruneCore
import SwiftUI

/// The capacity dial: a 270° scale with fine ticks, used space by kind on the outer arc,
/// and what Prune can reclaim on a thin signal-orange arc inside it.
struct DialView: View {
    struct Segment: Identifiable {
        let id: String
        let fraction: Double
        let color: Color
    }

    var segments: [Segment]
    /// Fraction of the disk that can be reclaimed, drawn on the inner arc.
    var reclaimable: Double
    /// Shows a moving sweep instead of segments while scanning.
    var scanning = false
    var diameter: CGFloat = 250
    var center: AnyView

    @State private var reveal: Double = 0

    private let sweepAngle = 270.0
    private let start = 135.0

    var body: some View {
        ZStack {
            Ticks(start: start, sweep: sweepAngle)
                .frame(width: diameter, height: diameter)

            ArcShape(start: start, sweep: sweepAngle, from: 0, to: 1)
                .stroke(Theme.track, style: StrokeStyle(lineWidth: ring, lineCap: .butt))
                .frame(width: diameter - 34, height: diameter - 34)

            if scanning {
                // Driven by the clock, so frequent counter updates can't restart it.
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                    let head = t * 1.15
                    ArcShape(start: start, sweep: sweepAngle, from: max(0, head - 0.15), to: min(1, head))
                        .stroke(Theme.accent.gradient, style: StrokeStyle(lineWidth: ring, lineCap: .butt))
                        .frame(width: diameter - 34, height: diameter - 34)
                }
            } else {
                ForEach(Array(layout.enumerated()), id: \.element.id) { _, s in
                    ArcShape(start: start, sweep: sweepAngle, from: s.from * reveal, to: s.to * reveal)
                        .stroke(s.color, style: StrokeStyle(lineWidth: ring, lineCap: .butt))
                        .frame(width: diameter - 34, height: diameter - 34)
                }
                // Inner scale: the part of the used space Prune can give back, ending where used space ends.
                let inner = diameter - 34 - ring * 2 - 12
                ArcShape(start: start, sweep: sweepAngle, from: 0, to: 1)
                    .stroke(Theme.track, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: inner, height: inner)
                if reclaimable > 0.001 {
                    let end = usedEnd
                    ArcShape(start: start, sweep: sweepAngle, from: max(0, end - reclaimable) * reveal, to: end * reveal)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: inner, height: inner)
                }
            }
            center
        }
        .frame(width: diameter, height: diameter)
        .onAppear { withAnimation(.spring(duration: 1.3, bounce: 0.12).delay(0.1)) { reveal = 1 } }
        .accessibilityElement(children: .combine)
    }

    private var ring: CGFloat { max(10, diameter * 0.052) }

    private var usedEnd: Double { min(1, segments.reduce(0) { $0 + $1.fraction }) }

    /// Segments laid end to end with a hairline gap between them.
    private var layout: [(id: String, from: Double, to: Double, color: Color)] {
        var out: [(String, Double, Double, Color)] = []
        var cursor = 0.0
        let gap = 0.004
        for s in segments where s.fraction > 0.0005 {
            let end = min(1, cursor + s.fraction)
            out.append((s.id, cursor, max(cursor, end - gap), s.color))
            cursor = end
        }
        return out.map { (id: $0.0, from: $0.1, to: $0.2, color: $0.3) }
    }
}

struct ArcShape: Shape {
    var start: Double
    var sweep: Double
    var from: Double
    var to: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(from, to) }
        set { from = newValue.first; to = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard to > from else { return p }
        let r = min(rect.width, rect.height) / 2
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: r,
                 startAngle: .degrees(start + sweep * from), endAngle: .degrees(start + sweep * to), clockwise: false)
        return p
    }
}

/// Fine ticks around the scale; every sixth one longer, like a gauge bezel.
private struct Ticks: View {
    let start: Double
    let sweep: Double
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2
            let count = 60
            for i in 0...count {
                let major = i % 6 == 0
                let angle = Angle.degrees(start + sweep * Double(i) / Double(count)).radians
                let len: CGFloat = major ? 7 : 3.5
                let p1 = CGPoint(x: c.x + cos(angle) * outer, y: c.y + sin(angle) * outer)
                let p2 = CGPoint(x: c.x + cos(angle) * (outer - len), y: c.y + sin(angle) * (outer - len))
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                ctx.stroke(path, with: .color(.primary.opacity(major ? 0.42 : 0.18)), lineWidth: major ? 1.2 : 0.8)
            }
        }
    }
}
