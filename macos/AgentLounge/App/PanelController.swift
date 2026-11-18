import AppKit
import Observation
import os
import SwiftUI

/// Size limits the SwiftUI content reads.
@Observable
final class PanelLayout {
    var maxListHeight: CGFloat = 520
}

/// Owns the panel window.
/// - Unpinned: opens under the status item and closes on an outside click or Escape.
/// - Pinned: floats above other windows, can be dragged, and keeps its position.
final class PanelController: NSObject, NSWindowDelegate {
    var anchorProvider: (() -> StatusItemController.Anchor?)?
    var onOpenSettings: (() -> Void)?

    private let store: SessionStore
    private let preferences: Preferences
    private let usage: UsageMonitor
    private let layout = PanelLayout()
    private let panel: LoungePanel
    private var outsideClickMonitor: Any?
    private var floatObservation: Task<Void, Never>?
    /// Time of the last close by an outside click. Stops the same click on the
    /// status item from opening the panel again.
    private var lastOutsideDismissal: Date = .distantPast
    private let logger = Logger(subsystem: "dev.agentlounge.AgentLounge", category: "Panel")

    init(store: SessionStore, preferences: Preferences, usage: UsageMonitor) {
        self.store = store
        self.preferences = preferences
        self.usage = usage
        panel = LoungePanel(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 240))
        super.init()
        panel.delegate = self
        panel.onCancel = { [weak self] in
            guard let self, !self.preferences.isPinned else { return }
            self.close()
        }
        installContent()
        applyPinState()
        observeFloatSetting()
    }

    private func observeFloatSetting() {
        let preferences = preferences
        floatObservation = Task { [weak self] in
            for await _ in Observations({ preferences.floatsWhenPinned }) {
                self?.applyPinState()
            }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible {
            close()
        } else if Date.now.timeIntervalSince(lastOutsideDismissal) > 0.3 {
            show()
        }
    }

    func show() {
        layout.maxListHeight = maxListHeight()
        position()
        panel.orderFrontRegardless()
        if !preferences.isPinned {
            panel.makeKey()
            installOutsideClickMonitor()
        }
    }

    func close() {
        removeOutsideClickMonitor()
        panel.orderOut(nil)
    }

    func togglePin() {
        preferences.isPinned.toggle()
        applyPinState()
        if preferences.isPinned {
            removeOutsideClickMonitor()
            savePinnedPosition()
        } else {
            preferences.pinnedTopLeft = nil
            if panel.isVisible {
                position()
                installOutsideClickMonitor()
            }
        }
    }

    // MARK: - Setup

    private func installContent() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: PanelMetrics.cornerRadius)

        let actions = PanelActions(
            toggleMute: { [weak self] in self?.preferences.isMuted.toggle() },
            togglePin: { [weak self] in self?.togglePin() },
            openSettings: { [weak self] in
                guard let self else { return }
                if !preferences.isPinned { close() }
                onOpenSettings?()
            },
            close: { [weak self] in self?.close() }
        )
        let root = PanelView(
            store: store,
            preferences: preferences,
            usage: usage,
            layout: layout,
            actions: actions,
            onHeightChange: { [weak self] height in
                // Resize outside the SwiftUI update pass.
                Task { @MainActor in self?.setContentHeight(height) }
            }
        )
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        background.layoutSubtreeIfNeeded()
    }

    private func applyPinState() {
        let pinned = preferences.isPinned
        // Unpinned it is a popover under the menu bar; pinned it floats unless the setting is off.
        panel.level = pinned ? (preferences.floatsWhenPinned ? .floating : .normal) : .statusBar
        panel.isMovable = pinned
        panel.isMovableByWindowBackground = pinned
    }

    // MARK: - Geometry

    private func position() {
        if preferences.isPinned,
           let saved = preferences.pinnedTopLeft,
           NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(saved) }) {
            panel.setFrameTopLeftPoint(saved)
            return
        }
        let width = panel.frame.width
        guard let anchor = anchorProvider?(),
              NSScreen.screens.contains(where: { $0.frame.intersects(anchor.frame) }) else {
            // No visible status item, e.g. a menu-bar manager (Ice, Thaw, Bartender) hides it.
            // Open at the top-right corner of the main screen instead.
            logger.info("Status item is not on screen; using top-right fallback position")
            guard let visible = NSScreen.main?.visibleFrame else {
                panel.center()
                return
            }
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - width - 8, y: visible.maxY - 6))
            return
        }
        let visible = (anchor.screen ?? NSScreen.main)?.visibleFrame ?? anchor.frame
        let x = min(max(anchor.frame.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: anchor.frame.minY - 6))
    }

    private func maxListHeight() -> CGFloat {
        let screen = anchorProvider?()?.screen ?? NSScreen.main
        let available = screen?.visibleFrame.height ?? 800
        return max(200, available * 0.8 - PanelMetrics.headerHeight)
    }

    /// Keep the top edge fixed when the content grows or shrinks.
    private func setContentHeight(_ height: CGFloat) {
        let height = ceil(height)
        var frame = panel.frame
        guard height > 0, abs(frame.height - height) >= 1 else { return }
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func savePinnedPosition() {
        preferences.pinnedTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - Outside click

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.dismissFromOutside()
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    private func dismissFromOutside() {
        guard panel.isVisible, !preferences.isPinned else { return }
        lastOutsideDismissal = .now
        close()
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        dismissFromOutside()
    }

    func windowDidMove(_ notification: Notification) {
        if preferences.isPinned, panel.isVisible {
            savePinnedPosition()
        }
    }
}
