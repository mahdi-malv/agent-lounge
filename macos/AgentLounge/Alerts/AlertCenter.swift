import AppKit
import os
import UserNotifications

/// Sounds and macOS notifications for card state changes (PLAN D5, M6).
/// Rules: `AlertRule`. Settings: `Preferences.alerts`, `isMuted`, `enabledSources`.
final class AlertCenter: NSObject, UNUserNotificationCenterDelegate {
    /// Same alert for the same card is dropped within this time (e.g. PermissionRequest then Notification).
    static let repeatWindow: TimeInterval = 5
    /// At most one sound in this time, so many agents finishing together do not make noise.
    static let soundGap: TimeInterval = 1.5

    /// Click on a notification: focus that card (set by the app).
    var onOpenCard: ((AgentSession.ID) -> Void)?
    /// Every alert that passed the rules and the repeat guard (phone stream, M8).
    var onAlert: ((AlertKind, AgentSession) -> Void)?

    private let store: SessionStore
    private let preferences: Preferences
    private var lastAlerts: [AgentSession.ID: (kind: AlertKind, at: Date)] = [:]
    private var lastSoundAt: Date = .distantPast
    private var askedForNotifications = false
    private let logger = Logger(subsystem: "dev.agentlounge.AgentLounge", category: "Alerts")

    init(store: SessionStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
        super.init()
    }

    /// Call once at launch. Asks for notification permission only when a notification setting is on.
    func start() {
        UNUserNotificationCenter.current().delegate = self
        if AlertKind.allCases.contains(where: { preferences.alert($0).showsNotification }) {
            requestNotificationPermission()
        }
    }

    /// Called after the store applied a hook event.
    func eventApplied(_ event: AgentEvent, before: SessionState?) {
        if case .sessionEnd = event.kind {
            lastAlerts[event.cardID] = nil
            return
        }
        // Deleted cards have no session here; a hidden card is shown again by its event.
        guard let session = store.session(event.cardID),
              preferences.isEnabled(session.source),
              let kind = AlertRule.alert(for: event.kind, before: before, after: session.state) else { return }

        let now = Date.now
        if let last = lastAlerts[session.id], last.kind == kind, now.timeIntervalSince(last.at) < Self.repeatWindow { return }
        lastAlerts[session.id] = (kind, now)
        logger.info("\(kind.rawValue, privacy: .public) alert for \(session.id, privacy: .public)")
        onAlert?(kind, session)

        let setting = preferences.alert(kind)
        if setting.playsSound, !preferences.isMuted, now.timeIntervalSince(lastSoundAt) >= Self.soundGap {
            lastSoundAt = now
            Self.play(setting.soundName)
        }
        if setting.showsNotification {
            post(kind, session: session)
        }
    }

    // MARK: - Sound

    /// Names of the system alert sounds, sorted.
    static var systemSoundNames: [String] {
        let directory = "/System/Library/Sounds"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.map { ($0 as NSString).deletingPathExtension }.filter { !$0.isEmpty }.sorted()
    }

    static func play(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.stop()
        sound.play()
    }

    // MARK: - Notifications

    func requestNotificationPermission() {
        guard !askedForNotifications else { return }
        askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                Logger(subsystem: "dev.agentlounge.AgentLounge", category: "Alerts")
                    .error("Notification permission error: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                Logger(subsystem: "dev.agentlounge.AgentLounge", category: "Alerts").info("Notifications not allowed")
            }
        }
    }

    private func post(_ kind: AlertKind, session: AgentSession) {
        requestNotificationPermission()
        let content = UNMutableNotificationContent()
        content.title = session.displayTitle
        content.subtitle = "\(kind.label) · \(session.hostBadgeText)"
        content.body = AlertRule.message(for: kind, session: session)
        content.threadIdentifier = session.id
        content.userInfo = ["cardID": session.id]
        // No notification sound: the app plays the chosen sound itself (and respects mute).
        let request = UNNotificationRequest(identifier: "\(session.id):\(kind.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error { logger.error("Notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = response.notification.request.content.userInfo["cardID"] as? String else { return }
        await MainActor.run { onOpenCard?(id) }
    }
}
