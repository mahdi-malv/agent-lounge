import AppKit
import SwiftUI

/// App icon artwork: three mascots in the lounge, on a dark rounded square (macOS icon grid:
/// 1024 canvas, 824 body). Rendered to PNGs by `scripts/make-icon.sh` (dev aid).
struct AppIconView: View {
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

            // Lounge floor.
            Capsule()
                .fill(Color.white.opacity(0.08))
                .frame(width: 620, height: 70)
                .offset(y: 250)

            StillAvatar(state: .running, seed: "lounge-app")
                .frame(height: 300)
                .offset(x: -215, y: 110)
            StillAvatar(state: .needsInput, seed: "android-shop")
                .frame(height: 300)
                .offset(x: 215, y: 110)
            StillAvatar(state: .idle, seed: "vault")
                .frame(height: 470)
                .offset(y: 20)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// Mascot in its still pose (no TimelineView, so `ImageRenderer` draws it at once).
private struct StillAvatar: View {
    let state: SessionState
    let seed: String

    var body: some View {
        Canvas { context, size in
            AvatarPainter(state: state, look: PlanetLook.make(seed: seed), time: 0).paint(in: &context, size: size)
        }
        .aspectRatio(AvatarPainter.designSize.width / AvatarPainter.designSize.height, contentMode: .fit)
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
