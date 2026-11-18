import SwiftUI

/// Agent Lounge mascot: a rounded critter with an antenna.
/// Body color = project. Face, antenna bulb, and badge = state.
///
/// - running: eyes scan left/right, body bobs, bulb glows.
/// - needsInput: wide eyes look up, "o" mouth, pulsing "!" badge.
/// - idle (done): happy closed eyes, smile, blush.
/// - error: grey-tinted body, X eyes, frown, red bulb.
struct AvatarView: View {
    let state: SessionState
    let color: Color
    var phase: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isAnimated: Bool {
        !reduceMotion && (state == .running || state == .needsInput)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimated)) { timeline in
            let time = isAnimated ? timeline.date.timeIntervalSinceReferenceDate + phase : 0
            Canvas { context, size in
                AvatarPainter(state: state, color: color, time: time).paint(in: &context, size: size)
            }
        }
        .aspectRatio(AvatarPainter.designSize.width / AvatarPainter.designSize.height, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Agent, \(state.label)")
    }
}

/// Draws in a 44 × 52 design space, scaled to the target size.
struct AvatarPainter {
    static let designSize = CGSize(width: 44, height: 52)

    let state: SessionState
    let color: Color
    /// Seconds. 0 = still pose.
    let time: Double

    private let ink = Color(red: 0.13, green: 0.12, blue: 0.17)

    private var baseColor: Color {
        state == .error ? color.mix(with: .gray, by: 0.5) : color
    }

    func paint(in context: inout GraphicsContext, size: CGSize) {
        context.scaleBy(x: size.width / Self.designSize.width, y: size.height / Self.designSize.height)

        drawFeet(&context)

        var upper = context
        upper.translateBy(x: 0, y: bob)
        drawAntenna(&upper)
        drawBody(&upper)
        drawFace(&upper)

        if state == .needsInput {
            drawAlertBadge(&context)
        }
    }

    // MARK: - Motion

    private var bob: Double {
        state == .running && time != 0 ? sin(time * 3.2) * 1.2 : 0
    }

    /// 1 = open, ~0 = closed. Short blink every 4.2 s.
    private var eyeOpenness: Double {
        guard time != 0 else { return 1 }
        let period = 4.2, duration = 0.16
        let t = time.truncatingRemainder(dividingBy: period)
        guard t < duration else { return 1 }
        return max(0.12, abs(t - duration / 2) / (duration / 2))
    }

    // MARK: - Parts

    private func drawFeet(_ c: inout GraphicsContext) {
        let foot = baseColor.mix(with: .black, by: 0.28)
        for x in [12.0, 24.0] {
            let rect = CGRect(x: x, y: 44, width: 8, height: 7)
            c.fill(Path(roundedRect: rect, cornerRadius: 3.5), with: .color(foot))
        }
    }

    private func drawAntenna(_ c: inout GraphicsContext) {
        var stem = Path()
        stem.move(to: CGPoint(x: 22, y: 13))
        stem.addLine(to: CGPoint(x: 22, y: 6.5))
        c.stroke(
            stem,
            with: .color(baseColor.mix(with: .black, by: 0.28)),
            style: StrokeStyle(lineWidth: 2, lineCap: .round)
        )

        let bulb = Path(ellipseIn: CGRect(x: 18.5, y: 2.5, width: 7, height: 7))
        switch state {
        case .running:
            let glow = time == 0 ? 1 : 0.55 + 0.45 * (0.5 + 0.5 * sin(time * 4))
            c.fill(bulb, with: .color(state.tint.opacity(glow)))
        case .needsInput, .error:
            c.fill(bulb, with: .color(state.tint))
        case .idle:
            c.fill(bulb, with: .color(baseColor.mix(with: .white, by: 0.45)))
        }
    }

    private func drawBody(_ c: inout GraphicsContext) {
        let rect = CGRect(x: 2, y: 12, width: 40, height: 36)
        let shape = Path(roundedRect: rect, cornerRadius: 13, style: .continuous)
        c.fill(
            shape,
            with: .linearGradient(
                Gradient(colors: [baseColor.mix(with: .white, by: 0.22), baseColor]),
                startPoint: CGPoint(x: 22, y: rect.minY),
                endPoint: CGPoint(x: 22, y: rect.maxY)
            )
        )
        // Soft highlight, top left.
        c.fill(Path(ellipseIn: CGRect(x: 8, y: 15, width: 10, height: 5)), with: .color(.white.opacity(0.28)))
    }

    private func drawFace(_ c: inout GraphicsContext) {
        let eyes = [CGPoint(x: 15, y: 27), CGPoint(x: 29, y: 27)]
        let line = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)

        switch state {
        case .running:
            let look = time == 0 ? 0 : sin(time * 1.3) * 1.8
            drawOpenEyes(&c, centers: eyes, size: CGSize(width: 9, height: 10.5), pupil: CGVector(dx: look, dy: 1))
            var mouth = Path()
            mouth.move(to: CGPoint(x: 19.5, y: 37))
            mouth.addLine(to: CGPoint(x: 24.5, y: 37))
            c.stroke(mouth, with: .color(ink), style: line)

        case .needsInput:
            drawOpenEyes(&c, centers: eyes, size: CGSize(width: 10.5, height: 12.5), pupil: CGVector(dx: 0, dy: -1.8))
            c.fill(Path(ellipseIn: CGRect(x: 20, y: 35, width: 4, height: 4.8)), with: .color(ink))

        case .idle:
            for eye in eyes {
                var arc = Path()
                arc.move(to: CGPoint(x: eye.x - 4, y: eye.y + 1.5))
                arc.addQuadCurve(to: CGPoint(x: eye.x + 4, y: eye.y + 1.5), control: CGPoint(x: eye.x, y: eye.y - 4))
                c.stroke(arc, with: .color(ink), style: line)
            }
            var smile = Path()
            smile.move(to: CGPoint(x: 18.5, y: 35.5))
            smile.addQuadCurve(to: CGPoint(x: 25.5, y: 35.5), control: CGPoint(x: 22, y: 39.5))
            c.stroke(smile, with: .color(ink), style: line)
            let blush = Color(red: 1, green: 0.45, blue: 0.55).opacity(0.45)
            c.fill(Path(ellipseIn: CGRect(x: 6, y: 31.5, width: 6, height: 3.5)), with: .color(blush))
            c.fill(Path(ellipseIn: CGRect(x: 32, y: 31.5, width: 6, height: 3.5)), with: .color(blush))

        case .error:
            let cross = StrokeStyle(lineWidth: 2.2, lineCap: .round)
            for eye in eyes {
                var x = Path()
                x.move(to: CGPoint(x: eye.x - 3.2, y: eye.y - 3.2))
                x.addLine(to: CGPoint(x: eye.x + 3.2, y: eye.y + 3.2))
                x.move(to: CGPoint(x: eye.x + 3.2, y: eye.y - 3.2))
                x.addLine(to: CGPoint(x: eye.x - 3.2, y: eye.y + 3.2))
                c.stroke(x, with: .color(ink), style: cross)
            }
            var frown = Path()
            frown.move(to: CGPoint(x: 18.5, y: 38.5))
            frown.addQuadCurve(to: CGPoint(x: 25.5, y: 38.5), control: CGPoint(x: 22, y: 34.5))
            c.stroke(frown, with: .color(ink), style: line)
        }
    }

    private func drawOpenEyes(_ c: inout GraphicsContext, centers: [CGPoint], size: CGSize, pupil: CGVector) {
        let openness = eyeOpenness
        for center in centers {
            let height = size.height * openness
            let eye = CGRect(x: center.x - size.width / 2, y: center.y - height / 2, width: size.width, height: height)
            c.fill(Path(ellipseIn: eye), with: .color(.white))
            guard openness > 0.5 else { continue }
            let radius = 2.6
            let dot = CGRect(
                x: center.x + pupil.dx - radius,
                y: center.y + pupil.dy - radius,
                width: radius * 2,
                height: radius * 2
            )
            c.fill(Path(ellipseIn: dot), with: .color(ink))
        }
    }

    private func drawAlertBadge(_ c: inout GraphicsContext) {
        let pulse = time == 0 ? 1 : 1 + 0.08 * sin(time * 5)
        let radius = 6.5 * pulse
        let center = CGPoint(x: 37, y: 9)
        let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        c.fill(circle, with: .color(state.tint))
        c.stroke(circle, with: .color(.white.opacity(0.9)), lineWidth: 1.2)
        c.draw(
            Text("!").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white),
            at: center
        )
    }
}

#Preview("Avatar states") {
    HStack(spacing: 16) {
        ForEach(SessionState.allCases, id: \.self) { state in
            VStack {
                AvatarView(state: state, color: ProjectPalette.colors[0])
                    .frame(width: 44, height: 52)
                Text(state.label).font(.caption)
            }
        }
    }
    .padding()
}
