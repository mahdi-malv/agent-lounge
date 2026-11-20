import AppKit
import SwiftUI

/// App icon artwork: a ringed planet with a small moon and stars, on a dark rounded square (macOS
/// icon grid: 1024 canvas, 824 body). Rendered to PNGs by `scripts/make-icon.sh` (dev aid).
///
/// The Android launcher icon (`ic_launcher_*.xml`) draws the same art. Positions are in planet
/// design units (`AvatarPainter.designSize`, 52 × 52), from the icon center. On Android, 1 unit = 1 dp.
struct AppIconView: View {
    /// Pixels per design unit: the planet canvas is 600 px wide.
    static let unit: Double = 600 / AvatarPainter.designSize.width

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.20, green: 0.18, blue: 0.34), Color(red: 0.09, green: 0.08, blue: 0.16)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay {
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 4)
                }
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 12)

            Canvas { context, size in
                context.translateBy(x: size.width / 2, y: size.height / 2)
                context.scaleBy(x: Self.unit, y: Self.unit)
                Self.drawStars(&context)
                Self.drawMoon(&context)
            }

            Canvas { context, size in
                AvatarPainter(state: .running, look: .appIcon, time: 0).paint(in: &context, size: size)
            }
            .frame(width: 600, height: 600)
        }
        .frame(width: 1024, height: 1024)
    }

    /// (x, y, radius, opacity)
    static let stars: [(Double, Double, Double, Double)] = [
        (15, -22, 0.8, 0.9), (23, -17, 0.5, 0.7), (4, -26, 0.5, 0.6),
        (-24, 16, 0.6, 0.7), (-8, 24, 0.5, 0.6), (21, 17, 0.7, 0.8),
    ]

    private static func drawStars(_ c: inout GraphicsContext) {
        for star in stars {
            let (x, y, r, opacity) = star
            c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(opacity)))
        }
    }

    /// Powder-blue moon at the top left (`PlanetPalette.all[3]`).
    private static func drawMoon(_ c: inout GraphicsContext) {
        let palette = PlanetPalette.all[3]
        let r: Double = 3.2
        var g = c
        g.translateBy(x: -19, y: -17)
        let body = Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
        g.clip(to: body)
        g.fill(body, with: .linearGradient(
            Gradient(colors: [palette.light, palette.base]),
            startPoint: CGPoint(x: 0, y: -r), endPoint: CGPoint(x: 0, y: r)
        ))
        for crater in [(0.9, 0.5, 0.75), (-1.0, 1.2, 0.5)] {
            let (x, y, cr) = crater
            g.fill(
                Path(ellipseIn: CGRect(x: x - cr, y: y - cr, width: cr * 2, height: cr * 2)),
                with: .color(palette.dark.opacity(0.55))
            )
        }
        g.fill(body, with: .radialGradient(
            Gradient(stops: [
                Gradient.Stop(color: .black.opacity(0), location: 0),
                Gradient.Stop(color: .black.opacity(0), location: 0.62),
                Gradient.Stop(color: .black.opacity(0.28), location: 1),
            ]),
            center: CGPoint(x: -r * 0.4, y: -r * 0.45), startRadius: 0, endRadius: CGFloat(r * 1.8)
        ))
    }
}

extension PlanetLook {
    /// The app icon planet: peach, cloud belts, one storm, lavender rings.
    static var appIcon: PlanetLook {
        let palette = PlanetPalette.all[5]
        var look = PlanetLook(identity: 5, palette: palette, radius: 14.5, period: 14)
        look.bands = [
            PlanetBand(y: -0.55, h: 0.18, color: palette.pale, opacity: 0.7),
            PlanetBand(y: -0.12, h: 0.24, color: palette.dark, opacity: 0.55),
            PlanetBand(y: 0.30, h: 0.16, color: palette.pale, opacity: 0.6),
            PlanetBand(y: 0.62, h: 0.20, color: palette.dark, opacity: 0.5),
        ]
        look.spots = [
            PlanetSpot(u: 0.56, y: 0.12, w: 0.42, h: 0.16, color: palette.dark, opacity: 0.75, rate: 1),
        ]
        look.rings = PlanetRings(tilt: -18, squash: 0.30, parts: [
            PlanetRingPart(rx: 1.36, width: 0.18, color: Color(red: 0.74, green: 0.68, blue: 0.92)),
            PlanetRingPart(rx: 1.62, width: 0.16, color: Color(red: 0.93, green: 0.89, blue: 1.00)),
        ])
        return look
    }
}

/// Writes the AppIcon.appiconset PNGs. Run by `scripts/make-icon.sh`.
enum AppIconRenderer {
    /// (file name, pixel size)
    static let files: [(String, Int)] = [
        ("icon_16.png", 16), ("icon_32.png", 32), ("icon_64.png", 64), ("icon_128.png", 128),
        ("icon_256.png", 256), ("icon_512.png", 512), ("icon_1024.png", 1024),
    ]

    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, size) in files {
            let renderer = ImageRenderer(content: AppIconView())
            renderer.scale = CGFloat(size) / 1024
            guard let image = renderer.cgImage else { continue }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { continue }
            try png.write(to: directory.appending(path: name))
        }
    }
}
