import SwiftUI

/// Deterministic random numbers from a name (FNV-1a seed, SplitMix64 steps), so an agent gets the
/// same planet on every launch.
struct SeededRandom {
    private var state: UInt64

    init(seed: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        state = hash
    }

    /// 0..<1
    mutating func next() -> Double {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z: UInt64 = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / 9_007_199_254_740_992
    }

    mutating func range(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * next()
    }

    /// 0..<count
    mutating func index(_ count: Int) -> Int {
        min(count - 1, Int(next() * Double(count)))
    }
}

/// Soft colors of one planet: light top, base, dark markings, pale clouds.
struct PlanetPalette {
    let light: Color
    let base: Color
    let dark: Color
    let pale: Color

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red, green: green, blue: blue)
    }

    private static func make(
        _ light: (Double, Double, Double), _ base: (Double, Double, Double),
        _ dark: (Double, Double, Double), _ pale: (Double, Double, Double)
    ) -> PlanetPalette {
        PlanetPalette(
            light: rgb(light.0, light.1, light.2),
            base: rgb(base.0, base.1, base.2),
            dark: rgb(dark.0, dark.1, dark.2),
            pale: rgb(pale.0, pale.1, pale.2)
        )
    }

    static let all: [PlanetPalette] = [
        make((1.00, 0.90, 0.82), (0.88, 0.72, 0.62), (0.60, 0.40, 0.36), (1.00, 0.97, 0.92)), // sand
        make((1.00, 0.88, 0.88), (0.90, 0.66, 0.68), (0.64, 0.38, 0.44), (1.00, 0.95, 0.94)), // rose
        make((0.90, 0.96, 0.86), (0.68, 0.80, 0.66), (0.40, 0.54, 0.44), (0.97, 1.00, 0.94)), // sage
        make((0.86, 0.93, 1.00), (0.62, 0.76, 0.92), (0.36, 0.48, 0.70), (0.95, 0.98, 1.00)), // powder blue
        make((0.93, 0.89, 1.00), (0.74, 0.68, 0.92), (0.48, 0.40, 0.68), (0.98, 0.96, 1.00)), // lavender
        make((1.00, 0.90, 0.78), (0.95, 0.70, 0.52), (0.72, 0.42, 0.30), (1.00, 0.96, 0.88)), // peach
        make((1.00, 0.95, 0.76), (0.94, 0.80, 0.50), (0.70, 0.54, 0.28), (1.00, 0.98, 0.90)), // butter
        make((0.86, 0.98, 0.95), (0.60, 0.84, 0.80), (0.32, 0.56, 0.56), (0.95, 1.00, 0.98)), // seafoam
        make((0.96, 0.86, 0.94), (0.80, 0.60, 0.76), (0.54, 0.34, 0.52), (1.00, 0.95, 0.99)), // mauve
        make((0.92, 0.92, 0.95), (0.72, 0.72, 0.80), (0.46, 0.46, 0.56), (0.98, 0.98, 1.00)), // stone
        make((1.00, 0.86, 0.80), (0.94, 0.60, 0.54), (0.68, 0.34, 0.34), (1.00, 0.94, 0.90)), // coral
        make((0.88, 0.94, 1.00), (0.66, 0.74, 0.96), (0.40, 0.44, 0.76), (0.96, 0.98, 1.00)), // periwinkle
        make((0.96, 0.88, 0.80), (0.78, 0.62, 0.52), (0.50, 0.36, 0.30), (1.00, 0.95, 0.88)), // cocoa
        make((0.94, 0.98, 0.80), (0.80, 0.88, 0.56), (0.52, 0.62, 0.32), (0.99, 1.00, 0.90)), // lime
        make((0.84, 0.96, 1.00), (0.56, 0.82, 0.94), (0.30, 0.54, 0.70), (0.94, 0.99, 1.00)), // sky
        make((1.00, 0.88, 0.94), (0.94, 0.64, 0.78), (0.70, 0.36, 0.54), (1.00, 0.95, 0.98)), // blush
    ]
}

// Sizes below are in planet radii unless noted. `u` is a longitude, 0..<1 (0.5 = facing us).

/// Straight cloud belt.
struct PlanetBand {
    let y: Double
    let h: Double
    let color: Color
    let opacity: Double
}

/// Oval feature that moves with the planet's rotation.
struct PlanetSpot {
    let u: Double
    let y: Double
    let w: Double
    let h: Double
    let color: Color
    let opacity: Double
    /// Speed relative to the surface (clouds move faster).
    let rate: Double
}

/// Wavy cloud line that moves with the planet's rotation.
struct PlanetSquiggle {
    let u: Double
    let y: Double
    let length: Double
    let amp: Double
    let wave: Double
    let width: Double
    let color: Color
    let opacity: Double
    let rate: Double
}

/// Jagged line that moves with the planet's rotation: a crack in ice, a canyon, a lava stream.
struct PlanetCrack {
    let u: Double
    let y: Double
    /// Corners of the line, as offsets from (`u`, `y`).
    let points: [CGPoint]
    let width: Double
    let color: Color
    let opacity: Double
    /// Lava: the line pulses with a glow in this color.
    let glow: Color?
    /// Shift of the pulse, so the lines do not pulse together.
    let phase: Double
}

/// Polar cap.
struct PlanetCap {
    let y: Double
    let w: Double
    let h: Double
    let color: Color
}

struct PlanetRingPart {
    let rx: Double
    let width: Double
    let color: Color
}

struct PlanetRings {
    /// Degrees.
    let tilt: Double
    /// Height / width of the ring ellipse.
    let squash: Double
    let parts: [PlanetRingPart]
}

private func rgbColor(_ red: Double, _ green: Double, _ blue: Double) -> Color {
    Color(red: red, green: green, blue: blue)
}

/// Random jagged line around (`u`, `y`). `heading` in radians, `step` = length of one piece.
private func makeCrack(
    _ random: inout SeededRandom, u: Double, y: Double, segments: Int, step: Double, heading: Double,
    width: Double, color: Color, opacity: Double, glow: Color?
) -> PlanetCrack {
    var points: [CGPoint] = [CGPoint(x: 0, y: 0)]
    var angle: Double = heading
    var offsetX: Double = 0
    var offsetY: Double = 0
    for _ in 0..<segments {
        angle += random.range(-0.75, 0.75)
        offsetX += cos(angle) * step
        offsetY += sin(angle) * step
        points.append(CGPoint(x: offsetX, y: offsetY))
    }
    // Center the line on its anchor, so it is out of sight when the anchor wraps around the planet.
    let xs: [Double] = points.map { Double($0.x) }
    let ys: [Double] = points.map { Double($0.y) }
    let midX: Double = ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2
    let midY: Double = ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2
    let centered: [CGPoint] = points.map { CGPoint(x: Double($0.x) - midX, y: Double($0.y) - midY) }
    let phase = random.range(0, 6.28)
    return PlanetCrack(
        u: u, y: y, points: centered, width: width, color: color, opacity: opacity, glow: glow, phase: phase
    )
}

/// How one session's planet looks.
///
/// Identities 0..<16 are made from a name: soft colors (`PlanetPalette.all`), size, cloud belts or
/// wavy clouds or dark land, polar caps, rings. Identities 16... are the five fixed worlds: blue
/// planet, red planet, grey moon, lava world, ice world.
struct PlanetLook {
    static let identityCount = PlanetPalette.all.count + 5

    /// What makes this planet different from the others on screen. See the type's note.
    let identity: Int
    let palette: PlanetPalette
    /// Design points.
    let radius: Double
    /// Seconds per turn.
    let period: Double
    var bands: [PlanetBand] = []
    var spots: [PlanetSpot] = []
    var squiggles: [PlanetSquiggle] = []
    var cracks: [PlanetCrack] = []
    var caps: [PlanetCap] = []
    var rings: PlanetRings? = nil

    /// `identity`: use this identity, not the one the name picks (when another planet has it).
    static func make(seed: String, identity: Int? = nil) -> PlanetLook {
        // The prefixes only shuffle which name gets which planet.
        var random = SeededRandom(seed: "orbit-69/" + seed)
        let ownColors = random.index(PlanetPalette.all.count)
        var kindRandom = SeededRandom(seed: "kind/" + seed)
        let kindRoll = kindRandom.next()
        let kindPick = kindRandom.index(5)
        // About 4 names in 10 get a fixed world.
        let ownIdentity = kindRoll < 0.4 ? PlanetPalette.all.count + kindPick : ownColors
        let chosen = identity ?? ownIdentity
        if chosen >= PlanetPalette.all.count {
            return fixedWorld(chosen - PlanetPalette.all.count)
        }
        let palette = PlanetPalette.all[chosen]
        // 0 = cloud belts, 1 = wavy clouds, 2 = dark land with clouds.
        let style = random.index(3)
        let ringRoll = random.next()
        let capRoll = random.next()
        let sizeRoll = random.next()
        let hasRings = ringRoll < 0.3
        let radius: Double = hasRings ? 13.5 : 15.5 + sizeRoll * 3
        let period = random.range(10, 18)
        var look = PlanetLook(identity: chosen, palette: palette, radius: radius, period: period)

        if style == 0 {
            let count = 3 + random.index(3)
            for index in 0..<count {
                let shift = random.range(-0.2, 0.2)
                let y: Double = -0.8 + (Double(index) + 0.5 + shift) * 1.6 / Double(count)
                let h = random.range(0.12, 0.26)
                let opacity = random.range(0.45, 0.75)
                let color = index % 2 == 0 ? palette.dark : palette.pale
                look.bands.append(PlanetBand(y: y, h: h, color: color, opacity: opacity))
            }
            for index in 0..<3 {
                let u: Double = (Double(index) + random.next()) / 3
                let y = random.range(-0.7, 0.7)
                let w = random.range(0.3, 0.6)
                look.spots.append(PlanetSpot(u: u, y: y, w: w, h: 0.08, color: palette.pale, opacity: 0.85, rate: 1))
            }
        } else if style == 1 {
            let upper = random.range(-0.6, -0.3)
            let lower = random.range(0.3, 0.6)
            look.bands.append(PlanetBand(y: upper, h: 0.2, color: palette.dark, opacity: 0.22))
            look.bands.append(PlanetBand(y: lower, h: 0.24, color: palette.dark, opacity: 0.22))
            for index in 0..<6 {
                let position: Double = Double(index) * 0.37 + random.range(0, 0.1)
                let u: Double = position - position.rounded(.down)
                let y: Double = -0.72 + Double(index) * 0.29 + random.range(-0.06, 0.06)
                let length = random.range(0.9, 1.5)
                let amp = random.range(0.05, 0.09)
                let wave = random.range(0.38, 0.58)
                let width = random.range(0.09, 0.12)
                let color = index % 2 == 0 ? palette.pale : palette.dark
                look.squiggles.append(PlanetSquiggle(
                    u: u, y: y, length: length, amp: amp, wave: wave, width: width,
                    color: color, opacity: 0.8, rate: 1
                ))
            }
        } else {
            for index in 0..<5 {
                let u: Double = (Double(index) + random.next()) / 5
                let y = random.range(-0.55, 0.55)
                let w = random.range(0.4, 0.9)
                let h = random.range(0.22, 0.42)
                look.spots.append(PlanetSpot(u: u, y: y, w: w, h: h, color: palette.dark, opacity: 0.6, rate: 1))
            }
            for index in 0..<3 {
                let u: Double = (Double(index) + random.next()) / 3
                let y = random.range(-0.6, 0.6)
                let length = random.range(0.7, 1.1)
                look.squiggles.append(PlanetSquiggle(
                    u: u, y: y, length: length, amp: 0.05, wave: 0.42, width: 0.09,
                    color: palette.pale, opacity: 0.9, rate: 1.35
                ))
            }
        }

        if style != 0, capRoll < 0.6 {
            let top = random.range(0.85, 1.1)
            look.caps.append(PlanetCap(y: -1.0, w: top, h: 0.30, color: palette.pale))
            if capRoll < 0.3 {
                let bottom = random.range(0.6, 0.9)
                look.caps.append(PlanetCap(y: 1.0, w: bottom, h: 0.24, color: palette.pale))
            }
        }

        if hasRings {
            let tilt = random.range(-24, 16)
            let squash = random.range(0.26, 0.34)
            look.rings = PlanetRings(tilt: tilt, squash: squash, parts: [
                PlanetRingPart(rx: 1.36, width: 0.20, color: palette.dark.mix(with: palette.base, by: 0.4)),
                PlanetRingPart(rx: 1.64, width: 0.20, color: palette.pale.mix(with: palette.base, by: 0.3)),
            ])
        }
        return look
    }

    // MARK: - Fixed worlds

    /// 0 = blue planet, 1 = red planet, 2 = grey moon, 3 = lava world, anything else = ice world.
    private static func fixedWorld(_ kind: Int) -> PlanetLook {
        let first = PlanetPalette.all.count
        let white = Color.white
        switch kind {
        case 0:
            // Blue planet: land, wavy clouds, polar caps.
            let land = rgbColor(0.44, 0.78, 0.48)
            let land2 = rgbColor(0.62, 0.82, 0.46)
            let palette = PlanetPalette(
                light: rgbColor(0.62, 0.83, 1.0), base: rgbColor(0.32, 0.60, 0.95), dark: land, pale: white
            )
            var look = PlanetLook(identity: first, palette: palette, radius: 18, period: 14)
            look.spots = [
                PlanetSpot(u: 0.42, y: -0.36, w: 0.66, h: 0.52, color: land, opacity: 1, rate: 1),
                PlanetSpot(u: 0.465, y: 0.04, w: 0.30, h: 0.40, color: land, opacity: 1, rate: 1),
                PlanetSpot(u: 0.50, y: 0.44, w: 0.38, h: 0.52, color: land2, opacity: 1, rate: 1),
                PlanetSpot(u: 0.82, y: -0.38, w: 0.92, h: 0.48, color: land, opacity: 1, rate: 1),
                PlanetSpot(u: 0.78, y: 0.20, w: 0.46, h: 0.60, color: land2, opacity: 1, rate: 1),
                PlanetSpot(u: 0.95, y: 0.56, w: 0.30, h: 0.22, color: land, opacity: 1, rate: 1),
                PlanetSpot(u: 0.12, y: 0.08, w: 0.26, h: 0.18, color: land, opacity: 1, rate: 1),
            ]
            let clouds: [(Double, Double, Double)] = [(0.30, -0.08, 0.70), (0.66, 0.36, 0.60), (0.02, 0.58, 0.56), (0.93, -0.58, 0.52)]
            for cloud in clouds {
                look.squiggles.append(PlanetSquiggle(
                    u: cloud.0, y: cloud.1, length: cloud.2, amp: 0.04, wave: 0.40, width: 0.10,
                    color: white, opacity: 0.92, rate: 1.35
                ))
            }
            look.caps = [
                PlanetCap(y: -1.0, w: 1.1, h: 0.30, color: white),
                PlanetCap(y: 1.0, w: 0.9, h: 0.24, color: white),
            ]
            return look

        case 1:
            // Red planet: dark plains, small craters, one canyon, polar caps.
            let dark = rgbColor(0.66, 0.28, 0.22)
            let crater = rgbColor(0.56, 0.22, 0.18)
            let cap = rgbColor(1.0, 0.96, 0.92)
            let palette = PlanetPalette(
                light: rgbColor(1.0, 0.70, 0.52), base: rgbColor(0.90, 0.46, 0.32), dark: dark, pale: cap
            )
            var look = PlanetLook(identity: first + 1, palette: palette, radius: 17, period: 14)
            var random = SeededRandom(seed: "mars")
            look.spots = [
                PlanetSpot(u: 0.45, y: -0.12, w: 0.80, h: 0.32, color: dark, opacity: 0.6, rate: 1),
                PlanetSpot(u: 0.55, y: 0.34, w: 0.46, h: 0.28, color: dark, opacity: 0.6, rate: 1),
                PlanetSpot(u: 0.90, y: 0.02, w: 0.66, h: 0.38, color: dark, opacity: 0.6, rate: 1),
                PlanetSpot(u: 0.15, y: -0.40, w: 0.46, h: 0.22, color: dark, opacity: 0.6, rate: 1),
                PlanetSpot(u: 0.20, y: 0.45, w: 0.40, h: 0.20, color: dark, opacity: 0.6, rate: 1),
            ]
            for index in 0..<6 {
                let size = random.range(0.10, 0.20)
                let u: Double = (Double(index) + random.next()) / 6
                let y = random.range(-0.65, 0.65)
                look.spots.append(PlanetSpot(u: u, y: y, w: size, h: size, color: crater, opacity: 0.7, rate: 1))
            }
            look.cracks = [
                makeCrack(
                    &random, u: 0.70, y: 0.30, segments: 5, step: 0.20, heading: 0.1,
                    width: 0.07, color: rgbColor(0.50, 0.18, 0.15), opacity: 0.8, glow: nil
                ),
            ]
            look.caps = [
                PlanetCap(y: -1.0, w: 0.9, h: 0.30, color: cap),
                PlanetCap(y: 1.0, w: 0.55, h: 0.18, color: cap),
            ]
            return look

        case 2:
            // Grey moon: dark seas and craters with a lit floor.
            let dark = rgbColor(0.50, 0.50, 0.56)
            let floor = rgbColor(0.82, 0.82, 0.86)
            let palette = PlanetPalette(
                light: rgbColor(0.93, 0.93, 0.95), base: rgbColor(0.72, 0.72, 0.76),
                dark: dark, pale: rgbColor(0.97, 0.97, 0.99)
            )
            var look = PlanetLook(identity: first + 2, palette: palette, radius: 16, period: 16)
            var random = SeededRandom(seed: "moon")
            for index in 0..<3 {
                let u: Double = (Double(index) + random.next()) / 3
                let y = random.range(-0.4, 0.4)
                let w = random.range(0.6, 0.9)
                let h = random.range(0.4, 0.6)
                look.spots.append(PlanetSpot(u: u, y: y, w: w, h: h, color: dark, opacity: 0.30, rate: 1))
            }
            for index in 0..<9 {
                let u: Double = (Double(index) + random.next()) / 9
                let y = random.range(-0.7, 0.7)
                let size = random.range(0.14, 0.34)
                look.spots.append(PlanetSpot(u: u, y: y, w: size, h: size, color: dark, opacity: 0.75, rate: 1))
                look.spots.append(PlanetSpot(
                    u: u + 0.008, y: y + 0.035, w: size * 0.72, h: size * 0.72, color: floor, opacity: 0.55, rate: 1
                ))
            }
            return look

        case 3:
            // Lava world: dark rock, lava streams that pulse, hot spots.
            let dark = rgbColor(0.13, 0.11, 0.15)
            let core = rgbColor(1.0, 0.82, 0.32)
            let glow = rgbColor(1.0, 0.40, 0.10)
            let palette = PlanetPalette(
                light: rgbColor(0.52, 0.44, 0.46), base: rgbColor(0.28, 0.23, 0.27), dark: dark, pale: core
            )
            var look = PlanetLook(identity: first + 3, palette: palette, radius: 16.5, period: 15)
            var random = SeededRandom(seed: "lava")
            for index in 0..<5 {
                let u: Double = (Double(index) + random.next()) / 5
                let y = random.range(-0.55, 0.55)
                let w = random.range(0.4, 0.8)
                let h = random.range(0.25, 0.45)
                look.spots.append(PlanetSpot(u: u, y: y, w: w, h: h, color: dark, opacity: 0.55, rate: 1))
            }
            for index in 0..<9 {
                let u: Double = (Double(index) + random.next()) / 9
                let y = random.range(-0.62, 0.62)
                let heading = random.range(0, 6.28)
                look.cracks.append(makeCrack(
                    &random, u: u, y: y, segments: 4, step: 0.21, heading: heading,
                    width: 0.07, color: core, opacity: 1, glow: glow
                ))
            }
            for index in 0..<4 {
                let size = random.range(0.12, 0.18)
                let u: Double = (Double(index) + random.next()) / 4
                let y = random.range(-0.6, 0.6)
                look.spots.append(PlanetSpot(u: u, y: y, w: size, h: size, color: glow, opacity: 0.95, rate: 1))
            }
            return look

        default:
            // Ice world: frost and a net of cracks.
            let line = rgbColor(0.34, 0.56, 0.74)
            let palette = PlanetPalette(
                light: rgbColor(0.97, 0.99, 1.0), base: rgbColor(0.74, 0.89, 0.97), dark: line, pale: white
            )
            var look = PlanetLook(identity: first + 4, palette: palette, radius: 17, period: 17)
            var random = SeededRandom(seed: "ice")
            for index in 0..<4 {
                let u: Double = (Double(index) + random.next()) / 4
                let y = random.range(-0.6, 0.6)
                let w = random.range(0.5, 0.9)
                let h = random.range(0.2, 0.4)
                look.spots.append(PlanetSpot(u: u, y: y, w: w, h: h, color: white, opacity: 0.55, rate: 1))
            }
            for index in 0..<10 {
                let u: Double = (Double(index) + random.next()) / 10
                let y = random.range(-0.65, 0.65)
                let heading = random.range(0, 3.14)
                let width = random.range(0.035, 0.065)
                look.cracks.append(makeCrack(
                    &random, u: u, y: y, segments: 5, step: 0.22, heading: heading,
                    width: width, color: line, opacity: 0.85, glow: nil
                ))
            }
            return look
        }
    }
}

/// Gives every live session its own planet: no two cards look the same.
///
/// The first session of a project gets the project's planet (the same on every launch). More
/// sessions of that project get sister planets. If another live session already has that identity
/// (the colors, or the fixed world), the planet takes the next free one.
@MainActor
enum PlanetRegistry {
    private struct Entry {
        let seed: String
        let look: PlanetLook
    }

    /// By session id.
    private static var entries: [String: Entry] = [:]

    /// Call with all live sessions before the cards draw. Forgets ended sessions (their planets
    /// are free again) and gives new sessions a planet, in list order.
    static func sync(_ sessions: [AgentSession]) {
        let live = Set(sessions.map(\.id))
        for id in Array(entries.keys) where !live.contains(id) {
            entries[id] = nil
        }
        for session in sessions where entries[session.id] == nil {
            assign(session)
        }
    }

    static func look(for session: AgentSession) -> PlanetLook {
        if let entry = entries[session.id] { return entry.look }
        return assign(session)
    }

    /// Seed and identity of the session's planet, for the phone (`PlanetLook.make(seed:identity:)`).
    static func planet(for session: AgentSession) -> (seed: String, identity: Int) {
        if entries[session.id] == nil { assign(session) }
        let entry = entries[session.id]!
        return (entry.seed, entry.look.identity)
    }

    @discardableResult
    private static func assign(_ session: AgentSession) -> PlanetLook {
        let usedSeeds = Set(entries.values.map(\.seed))
        let usedIdentities = Set(entries.values.map(\.look.identity))

        var seed = session.projectName
        var copy = 2
        while usedSeeds.contains(seed) {
            seed = "\(session.projectName) #\(copy)"
            copy += 1
        }

        var look = PlanetLook.make(seed: seed)
        let count = PlanetLook.identityCount
        if usedIdentities.contains(look.identity), usedIdentities.count < count {
            var identity = look.identity
            while usedIdentities.contains(identity) {
                identity = (identity + 1) % count
            }
            look = PlanetLook.make(seed: seed, identity: identity)
        }
        entries[session.id] = Entry(seed: seed, look: look)
        return look
    }
}

/// How one subagent's moon looks. Made from the subagent's name, so the moon in orbit and the
/// moon in the subagent's row match.
struct MoonLook {
    let palette: PlanetPalette
    /// Craters: `w` = `h` = diameter.
    let craters: [PlanetSpot]

    static func make(name: String) -> MoonLook {
        var random = SeededRandom(seed: name)
        let palette = PlanetPalette.all[random.index(PlanetPalette.all.count)]
        var marks = SeededRandom(seed: name + "#moon")
        var craters: [PlanetSpot] = []
        for index in 0..<5 {
            let u: Double = (Double(index) + marks.next()) / 5
            let y = marks.range(-0.6, 0.6)
            let size = marks.range(0.28, 0.5)
            craters.append(PlanetSpot(u: u, y: y, w: size, h: size, color: palette.dark, opacity: 0.55, rate: 1))
        }
        return MoonLook(palette: palette, craters: craters)
    }
}
