import AppKit
import SwiftUI

enum PanelMetrics {
    static let width: CGFloat = 384
    static let cornerRadius: CGFloat = 18
    static let headerHeight: CGFloat = 44
    static let tileCornerRadius: CGFloat = 14
}

extension SessionState {
    /// Status-item dot color.
    var statusColor: NSColor {
        switch self {
        case .running: .systemGreen
        case .needsInput: .systemOrange
        case .idle: .secondaryLabelColor
        case .error: .systemRed
        }
    }

    /// Accent for progress bars, borders, and the avatar antenna.
    var tint: Color {
        switch self {
        case .running: Color(nsColor: .systemGreen)
        case .needsInput: Color(nsColor: .systemOrange)
        case .idle: Color(nsColor: .systemGray)
        case .error: Color(nsColor: .systemRed)
        }
    }
}

/// One stable color per project, so all cards of a project look the same.
enum ProjectPalette {
    static let colors: [Color] = [
        Color(red: 0.38, green: 0.56, blue: 0.95), // blue
        Color(red: 0.95, green: 0.50, blue: 0.72), // pink
        Color(red: 0.97, green: 0.68, blue: 0.40), // peach
        Color(red: 0.38, green: 0.80, blue: 0.56), // green
        Color(red: 0.67, green: 0.57, blue: 0.98), // violet
        Color(red: 0.27, green: 0.79, blue: 0.79), // teal
        Color(red: 0.96, green: 0.80, blue: 0.33), // yellow
        Color(red: 0.66, green: 0.85, blue: 0.38), // lime
        Color(red: 0.36, green: 0.72, blue: 0.97), // sky
    ]

    static func color(for project: String) -> Color {
        colors[Int(fnv1a(project) % UInt64(colors.count))]
    }

    /// Animation offset in seconds, so avatars do not move in sync.
    static func phase(for key: String) -> Double {
        Double(fnv1a(key) % 1000) / 97
    }

    /// Stable across launches (unlike `Hasher`).
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

extension AgentSession {
    /// Second line of the compact row.
    var subtitle: String {
        switch state {
        case .running:
            activity ?? "Thinking…"
        case .needsInput:
            attention ?? "Waiting for your input"
        case .idle:
            lastAssistantMessage?.firstLine ?? "Ready for a prompt"
        case .error:
            attention ?? "Stopped with an error"
        }
    }

    var hostBadgeText: String {
        if agent == .claude || host == .codexApp { return host.label }
        return "\(agent.label) · \(host.label)"
    }
}

/// Agent text often has inline markdown (`code`, **bold**). Render it; keep line breaks.
enum InlineMarkdown {
    static func text(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}
