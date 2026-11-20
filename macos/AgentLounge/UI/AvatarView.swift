import SwiftUI

/// Agent Lounge avatar: a planet. Each session has its own planet (`PlanetRegistry`, `PlanetLook`).
/// Running subagents orbit it as moons (`MoonLook`).
///
/// - running: the planet turns and floats, moons orbit, lava pulses.
/// - needsInput: the planet rocks, orange glow, pulsing "!" badge.
/// - idle (done): the sun shines from behind the planet.
/// - error: eclipse, a shadow covers half of the planet.
struct AvatarView: View {
    let state: SessionState
    /// The session's planet.
    let look: PlanetLook
    /// Names of the running subagents, drawn as moons (at most 5).
    var moons: [String] = []
    var phase: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isAnimated: Bool {
        !reduceMotion && (state == .running || state == .needsInput)
    }

    var body: some View {
        let moonLooks = moons.prefix(5).map { MoonLook.make(name: $0) }
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimated)) { timeline in
            let time = isAnimated ? timeline.date.timeIntervalSinceReferenceDate + phase : 0
            Canvas { context, size in
                AvatarPainter(state: state, look: look, moons: moonLooks, time: time).paint(in: &context, size: size)
            }
        }
        .aspectRatio(AvatarPainter.designSize.width / AvatarPainter.designSize.height, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Agent, \(state.label)")
    }
}

/// A subagent's moon, for its row under the parent card. Turns while the parent runs.
struct MoonAvatarView: View {
    let name: String
    var isAnimated: Bool = false
    var phase: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let look = MoonLook.make(name: name)
        let animated = isAnimated && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { timeline in
            let time = animated ? timeline.date.timeIntervalSinceReferenceDate + phase : 0
            Canvas { context, size in
                MoonPainter(look: look, time: time).paint(in: &context, size: size)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

// MARK: - Shared drawing

private func oval(x: Double, y: Double, width: Double, height: Double) -> Path {
    Path(ellipseIn: CGRect(x: x, y: y, width: width, height: height))
}

/// Horizontal place of longitude `u`, in radii. -1...1 is the side that faces us.
private func place(_ u: Double) -> Double {
    (u - u.rounded(.down)) * 4 - 2
}

/// Light at the top, like the sky side of a marble. Draw inside a clip of the globe.
private func fillGlobe(_ g: inout GraphicsContext, radius r: Double, palette: PlanetPalette) {
    let square = Path(CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
    g.fill(
        square,
        with: .linearGradient(
            Gradient(colors: [palette.light, palette.base]),
            startPoint: CGPoint(x: 0, y: -r),
            endPoint: CGPoint(x: 0, y: r)
        )
    )
}

/// Soft night side at the bottom right and a highlight at the top left. Draw inside a clip of the globe.
private func shadeGlobe(_ g: inout GraphicsContext, radius r: Double) {
    let square = Path(CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
    let shade = Gradient(stops: [
        Gradient.Stop(color: Color.black.opacity(0), location: 0),
        Gradient.Stop(color: Color.black.opacity(0), location: 0.62),
        Gradient.Stop(color: Color.black.opacity(0.28), location: 1),
    ])
    g.fill(
        square,
        with: .radialGradient(
            shade,
            center: CGPoint(x: -r * 0.4, y: -r * 0.45),
            startRadius: 0,
            endRadius: CGFloat(r * 1.8)
        )
    )
    g.fill(
        oval(x: -r * 0.66, y: -r * 0.74, width: r * 0.56, height: r * 0.30),
        with: .color(Color.white.opacity(0.30))
    )
}

private func fillSpots(_ g: inout GraphicsContext, spots: [PlanetSpot], radius r: Double, turns: Double) {
    for spot in spots {
        let x: Double = place(spot.u + turns * spot.rate) * r
        let shape = oval(x: x - spot.w * r / 2, y: (spot.y - spot.h / 2) * r, width: spot.w * r, height: spot.h * r)
        g.fill(shape, with: .color(spot.color.opacity(spot.opacity)))
    }
}

// MARK: - Planet painter

/// Draws in a 52 × 52 design space, scaled to the target size.
struct AvatarPainter {
    static let designSize = CGSize(width: 52, height: 52)

    let state: SessionState
    let look: PlanetLook
    var moons: [MoonLook] = []
    /// Seconds. 0 = still pose.
    let time: Double

    func paint(in context: inout GraphicsContext, size: CGSize) {
        context.scaleBy(x: size.width / Self.designSize.width, y: size.height / Self.designSize.height)

        // Planet-centered space.
        var space = context
        space.translateBy(x: 26, y: 26 + bob)
        switch state {
        case .idle:
            drawSun(&space)
        case .needsInput:
            drawHalo(&space)
        case .running, .error:
            break
        }
        drawMoons(&space, behind: true)
        drawRings(&space, back: true)
        drawGlobe(&space)
        drawRings(&space, back: false)
        drawMoons(&space, behind: false)

        if state == .needsInput {
            drawAlertBadge(&context)
        }
    }

    // MARK: - Motion

    private var bob: Double {
        state == .running && time != 0 ? sin(time * 1.6) * 0.8 : 0
    }

    /// Turns of the planet so far. While it waits for input it only rocks from side to side.
    private var turns: Double {
        guard time != 0 else { return 0 }
        return state == .needsInput ? 0.035 * sin(time * 2.2) : time / look.period
    }

    // MARK: - Parts

    /// Done: the sun shines from behind the planet.
    private func drawSun(_ c: inout GraphicsContext) {
        let r = look.radius
        let sun = Color(red: 1.0, green: 0.80, blue: 0.30)
        let outer: Double = r + 7
        let solid: Double = (r + 0.8) / outer
        let gradient = Gradient(stops: [
            Gradient.Stop(color: sun.opacity(0.95), location: 0),
            Gradient.Stop(color: sun.opacity(0.95), location: CGFloat(solid)),
            Gradient.Stop(color: sun.opacity(0), location: 1),
        ])
        c.fill(
            oval(x: -outer, y: -outer, width: outer * 2, height: outer * 2),
            with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: CGFloat(outer))
        )
        // Rays, long and short in turn.
        let inner: Double = r + 0.5
        let half: Double = 0.085
        for index in 0..<12 {
            let angle: Double = Double(index) * Double.pi / 6 + 0.26
            let tip: Double = r + (index % 2 == 0 ? 6.5 : 4.2)
            var ray = Path()
            ray.move(to: CGPoint(x: cos(angle - half) * inner, y: sin(angle - half) * inner))
            ray.addLine(to: CGPoint(x: cos(angle) * tip, y: sin(angle) * tip))
            ray.addLine(to: CGPoint(x: cos(angle + half) * inner, y: sin(angle + half) * inner))
            ray.closeSubpath()
            c.fill(ray, with: .color(sun.opacity(0.9)))
        }
    }

    /// Needs input: thin pulsing glow in the state color, right around the planet.
    private func drawHalo(_ c: inout GraphicsContext) {
        let r = look.radius
        let pulse: Double = time == 0 ? 1 : 0.5 + 0.5 * sin(time * 5)
        let strength: Double = 0.55 + 0.45 * pulse
        let outer: Double = r + 4
        let solid: Double = (r + 0.6) / outer
        let tint = state.tint
        let gradient = Gradient(stops: [
            Gradient.Stop(color: tint.opacity(strength), location: 0),
            Gradient.Stop(color: tint.opacity(strength), location: CGFloat(solid)),
            Gradient.Stop(color: tint.opacity(0), location: 1),
        ])
        c.fill(
            oval(x: -outer, y: -outer, width: outer * 2, height: outer * 2),
            with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: CGFloat(outer))
        )
    }

    private func drawGlobe(_ c: inout GraphicsContext) {
        let r = look.radius
        let spin = turns

        var g = c
        g.clip(to: oval(x: -r, y: -r, width: r * 2, height: r * 2))
        fillGlobe(&g, radius: r, palette: look.palette)

        for band in look.bands {
            let rect = CGRect(x: -r, y: (band.y - band.h / 2) * r, width: r * 2, height: band.h * r)
            g.fill(Path(rect), with: .color(band.color.opacity(band.opacity)))
        }

        fillSpots(&g, spots: look.spots, radius: r, turns: spin)

        let steps = 24
        for squiggle in look.squiggles {
            let start: Double = place(squiggle.u + spin * squiggle.rate) * r
            var line = Path()
            for step in 0...steps {
                let t: Double = (Double(step) / Double(steps) - 0.5) * squiggle.length
                let x: Double = start + t * r
                let y: Double = (squiggle.y + squiggle.amp * sin(t / squiggle.wave * Double.pi * 2)) * r
                if step == 0 {
                    line.move(to: CGPoint(x: x, y: y))
                } else {
                    line.addLine(to: CGPoint(x: x, y: y))
                }
            }
            g.stroke(
                line,
                with: .color(squiggle.color.opacity(squiggle.opacity)),
                style: StrokeStyle(lineWidth: CGFloat(squiggle.width * r), lineCap: .round, lineJoin: .round)
            )
        }

        for crack in look.cracks {
            let start: Double = place(crack.u + spin) * r
            var line = Path()
            for (index, point) in crack.points.enumerated() {
                let corner = CGPoint(x: start + Double(point.x) * r, y: (crack.y + Double(point.y)) * r)
                if index == 0 {
                    line.move(to: corner)
                } else {
                    line.addLine(to: corner)
                }
            }
            if let glow = crack.glow {
                // Lava: a wide glow under a bright core, both pulse.
                let pulse: Double = time == 0 ? 0.7 : 0.5 + 0.5 * sin(time * 2.4 + crack.phase)
                let glowWidth: Double = crack.width * r * 3
                let coreWidth: Double = crack.width * r * (0.9 + 0.3 * pulse)
                g.stroke(
                    line,
                    with: .color(glow.opacity(0.30 + 0.30 * pulse)),
                    style: StrokeStyle(lineWidth: CGFloat(glowWidth), lineCap: .round, lineJoin: .round)
                )
                g.stroke(
                    line,
                    with: .color(crack.color.opacity(0.70 + 0.30 * pulse)),
                    style: StrokeStyle(lineWidth: CGFloat(coreWidth), lineCap: .round, lineJoin: .round)
                )
            } else {
                g.stroke(
                    line,
                    with: .color(crack.color.opacity(crack.opacity)),
                    style: StrokeStyle(lineWidth: CGFloat(crack.width * r), lineCap: .round, lineJoin: .round)
                )
            }
        }

        for cap in look.caps {
            let shape = oval(x: -cap.w * r / 2, y: (cap.y - cap.h / 2) * r, width: cap.w * r, height: cap.h * r)
            g.fill(shape, with: .color(cap.color))
        }

        shadeGlobe(&g, radius: r)

        if state == .error {
            // Eclipse: a round shadow over the right half.
            let shadowRadius: Double = r * 1.35
            let centerX: Double = r * 1.05
            let centerY: Double = r * 0.2
            g.fill(
                oval(
                    x: centerX - shadowRadius, y: centerY - shadowRadius,
                    width: shadowRadius * 2, height: shadowRadius * 2
                ),
                with: .color(Color(red: 0.05, green: 0.05, blue: 0.12).opacity(0.72))
            )
        }
    }

    /// `back`: the half behind the planet (drawn first). Otherwise the half in front.
    private func drawRings(_ c: inout GraphicsContext, back: Bool) {
        guard let rings = look.rings else { return }
        let r = look.radius
        var g = c
        g.rotate(by: .degrees(rings.tilt))
        g.clip(to: Path(CGRect(x: -40, y: back ? -40 : 0, width: 80, height: 40)))
        for part in rings.parts {
            let rx: Double = part.rx * r
            let ry: Double = rx * rings.squash
            let color = back ? part.color.mix(with: .black, by: 0.18) : part.color
            g.stroke(
                oval(x: -rx, y: -ry, width: rx * 2, height: ry * 2),
                with: .color(color),
                lineWidth: CGFloat(part.width * r)
            )
        }
    }

    /// One moon per running subagent. `behind`: the moons on the far side of the orbit (drawn first).
    private func drawMoons(_ c: inout GraphicsContext, behind: Bool) {
        guard !moons.isEmpty else { return }
        var g = c
        g.rotate(by: .degrees(look.rings?.tilt ?? -12))
        for (index, moon) in moons.enumerated() {
            let i = Double(index)
            let angle: Double = time * (1.15 - 0.17 * i) + i * 2.4 + 0.3
            let isBehind = sin(angle) < 0
            guard isBehind == behind else { continue }
            let rx: Double = 23 * (1 - 0.07 * Double(index % 3))
            let ry: Double = rx * 0.30
            let x: Double = cos(angle) * rx
            let y: Double = sin(angle) * ry
            let mr: Double = 2.6 * (isBehind ? 0.85 : 1)
            let body = oval(x: x - mr, y: y - mr, width: mr * 2, height: mr * 2)
            g.fill(body, with: .color(moon.palette.base))
            g.fill(
                oval(x: x - mr * 0.75, y: y - mr * 0.8, width: mr * 1.0, height: mr * 0.9),
                with: .color(moon.palette.light.opacity(0.9))
            )
            g.stroke(body, with: .color(Color.black.opacity(0.25)), lineWidth: 0.4)
        }
    }

    private func drawAlertBadge(_ c: inout GraphicsContext) {
        let pulse = time == 0 ? 1 : 1 + 0.08 * sin(time * 5)
        let radius = 6.5 * pulse
        let center = CGPoint(x: 44.5, y: 8)
        let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        c.fill(circle, with: .color(state.tint))
        c.stroke(circle, with: .color(.white.opacity(0.9)), lineWidth: 1.2)
        c.draw(
            Text("!").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white),
            at: center
        )
    }
}

// MARK: - Moon painter

/// Draws in a 22 × 22 design space, scaled to the target size.
struct MoonPainter {
    let look: MoonLook
    /// Seconds. 0 = still pose.
    let time: Double

    func paint(in context: inout GraphicsContext, size: CGSize) {
        context.scaleBy(x: size.width / 22, y: size.height / 22)
        let r: Double = 9
        var g = context
        g.translateBy(x: 11, y: 11)
        g.clip(to: oval(x: -r, y: -r, width: r * 2, height: r * 2))
        fillGlobe(&g, radius: r, palette: look.palette)
        fillSpots(&g, spots: look.craters, radius: r, turns: time == 0 ? 0 : time / 8)
        shadeGlobe(&g, radius: r)
    }
}

#Preview("Planets") {
    let names = ["lounge-app", "android-shop", "vault", "billing-api", "design-tokens", "website"]
    return VStack(spacing: 12) {
        ForEach(names, id: \.self) { name in
            HStack(spacing: 16) {
                ForEach(SessionState.allCases, id: \.self) { state in
                    AvatarView(
                        state: state,
                        look: PlanetLook.make(seed: name),
                        moons: state == .running ? ["Explore", "Plan"] : []
                    )
                        .frame(width: 52, height: 52)
                }
                MoonAvatarView(name: name)
                    .frame(width: 22, height: 22)
                Text(name).font(.caption)
            }
        }
    }
    .padding()
}
