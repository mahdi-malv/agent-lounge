import AppKit
import Observation

/// Menu-bar icon: lounge glyph + status dot + card count (PLAN D4).
/// Left click toggles the panel. Right click (or control-click) opens the menu.
final class StatusItemController: NSObject {
    struct Anchor {
        let frame: NSRect
        let screen: NSScreen?
    }

    var onPrimaryClick: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    private let store: SessionStore
    private let statusItem: NSStatusItem
    private var observation: Task<Void, Never>?

    init(store: SessionStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        observeStore()
    }

    /// Status-item button frame in screen coordinates.
    var anchor: Anchor? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return Anchor(frame: frame, screen: window.screen)
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        let image = NSImage(systemSymbolName: "sofa.fill", accessibilityDescription: "Agent Lounge")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Agent Lounge"
    }

    private func observeStore() {
        let store = store
        observation = Task { [weak self] in
            for await summary in Observations({ store.summary }) {
                self?.render(summary)
            }
        }
    }

    private func render(_ summary: StoreSummary) {
        guard let button = statusItem.button else { return }
        guard summary.count > 0 else {
            button.attributedTitle = NSAttributedString()
            button.setAccessibilityLabel("Agent Lounge, no agents")
            return
        }

        // One colored dot and count per state, most urgent first: " ● 1 ● 5".
        let title = NSMutableAttributedString()
        for item in summary.counts {
            title.append(NSAttributedString(string: " ●", attributes: [
                .foregroundColor: item.state.statusColor,
                .font: NSFont.systemFont(ofSize: 9),
                .baselineOffset: 1.5,
            ]))
            title.append(NSAttributedString(string: " \(item.count)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            ]))
        }
        button.attributedTitle = title
        button.setAccessibilityLabel("Agent Lounge, \(summary.count) agents: \(summary.spokenCounts)")
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsMenu, let menu = menuProvider?() {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            onPrimaryClick?()
        }
    }
}
