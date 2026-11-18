import SwiftUI

/// Thin capsule bar. `fraction == nil` shows an indeterminate sliding segment.
struct LoungeProgressBar: View {
    let fraction: Double?
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.10))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    if let fraction {
                        Capsule()
                            .fill(tint)
                            .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                    } else {
                        IndeterminateSegment(tint: tint, trackWidth: proxy.size.width, isAnimated: !reduceMotion)
                    }
                }
            }
            .clipShape(Capsule())
            .frame(height: 5)
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }
}

private struct IndeterminateSegment: View {
    let tint: Color
    let trackWidth: CGFloat
    let isAnimated: Bool

    private let period = 1.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimated)) { timeline in
            let segment = trackWidth * 0.32
            let t = isAnimated
                ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                : 0.34
            Capsule()
                .fill(tint.opacity(0.85))
                .frame(width: segment)
                .offset(x: -segment + (trackWidth + segment) * t)
        }
    }
}
