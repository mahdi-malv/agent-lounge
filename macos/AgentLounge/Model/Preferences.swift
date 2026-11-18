import AppKit
import Observation

/// Sound and notification choice for one alert kind.
nonisolated struct AlertSetting: Codable, Hashable, Sendable {
    var playsSound: Bool
    /// System sound name (file in /System/Library/Sounds without extension), e.g. "Glass".
    var soundName: String
    var showsNotification: Bool
}

/// User settings saved in UserDefaults (PLAN §6). Launch at login is not stored here:
/// `SMAppService` owns that state.
@Observable
final class Preferences {
    private enum Key {
        static let pinned = "panel.pinned"
        static let pinnedTopLeft = "panel.pinnedTopLeft"
        static let floatsWhenPinned = "panel.floatsWhenPinned"
        static let autoHideDoneMinutes = "panel.autoHideDoneMinutes"
        static let muted = "sound.muted"
        static let showsUsage = "usage.shown"
        static let claudeUsage = "usage.claude.enabled"
        static func alert(_ kind: AlertKind) -> String { "alert.\(kind.rawValue)" }
        static func source(_ source: SessionSource) -> String { "source.\(source.rawValue).enabled" }
    }

    static let defaultAlerts: [AlertKind: AlertSetting] = [
        .needsInput: AlertSetting(playsSound: true, soundName: "Glass", showsNotification: true),
        .done: AlertSetting(playsSound: true, soundName: "Tink", showsNotification: false),
        .error: AlertSetting(playsSound: true, soundName: "Basso", showsNotification: true),
    ]

    /// Choices for the auto-hide picker, in minutes. 0 = off.
    static let autoHideChoices = [0, 5, 15, 30, 60, 120]

    @ObservationIgnored
    private let defaults: UserDefaults

    var isPinned: Bool {
        didSet { defaults.set(isPinned, forKey: Key.pinned) }
    }

    /// Global sound mute (panel button, menu, settings). Notifications still show.
    var isMuted: Bool {
        didSet { defaults.set(isMuted, forKey: Key.muted) }
    }

    /// Pinned panel floats above other windows. Off: it is a normal window.
    var floatsWhenPinned: Bool {
        didSet { defaults.set(floatsWhenPinned, forKey: Key.floatsWhenPinned) }
    }

    /// Hide done cards after this many minutes without events. 0 = off.
    var autoHideDoneMinutes: Int {
        didSet { defaults.set(autoHideDoneMinutes, forKey: Key.autoHideDoneMinutes) }
    }

    /// Usage bar at the top of the panel.
    var showsUsage: Bool {
        didSet { defaults.set(showsUsage, forKey: Key.showsUsage) }
    }

    /// Read the Claude Code sign-in from the Keychain to get Claude plan usage. Off by default:
    /// macOS asks for Keychain access.
    var claudeUsageEnabled: Bool {
        didSet { defaults.set(claudeUsageEnabled, forKey: Key.claudeUsage) }
    }

    var alerts: [AlertKind: AlertSetting] {
        didSet {
            for kind in AlertKind.allCases where alerts[kind] != oldValue[kind] {
                if let data = try? JSONEncoder().encode(alerts[kind]) {
                    defaults.set(data, forKey: Key.alert(kind))
                }
            }
        }
    }

    var enabledSources: Set<SessionSource> {
        didSet {
            for source in SessionSource.allCases {
                defaults.set(enabledSources.contains(source), forKey: Key.source(source))
            }
        }
    }

    /// Top-left screen point of the pinned panel. Nil = open under the status item.
    var pinnedTopLeft: NSPoint? {
        didSet {
            if let pinnedTopLeft {
                defaults.set(NSStringFromPoint(pinnedTopLeft), forKey: Key.pinnedTopLeft)
            } else {
                defaults.removeObject(forKey: Key.pinnedTopLeft)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isPinned = defaults.bool(forKey: Key.pinned)
        isMuted = defaults.bool(forKey: Key.muted)
        floatsWhenPinned = defaults.object(forKey: Key.floatsWhenPinned) as? Bool ?? true
        autoHideDoneMinutes = max(0, defaults.integer(forKey: Key.autoHideDoneMinutes))
        showsUsage = defaults.object(forKey: Key.showsUsage) as? Bool ?? true
        claudeUsageEnabled = defaults.bool(forKey: Key.claudeUsage)
        pinnedTopLeft = defaults.string(forKey: Key.pinnedTopLeft).map(NSPointFromString)

        var alerts = Self.defaultAlerts
        for kind in AlertKind.allCases {
            if let data = defaults.data(forKey: Key.alert(kind)),
               let setting = try? JSONDecoder().decode(AlertSetting.self, from: data) {
                alerts[kind] = setting
            }
        }
        self.alerts = alerts

        enabledSources = Set(SessionSource.allCases.filter { source in
            defaults.object(forKey: Key.source(source)) as? Bool ?? true
        })
    }

    func alert(_ kind: AlertKind) -> AlertSetting {
        alerts[kind] ?? Self.defaultAlerts[kind]!
    }

    func setAlert(_ kind: AlertKind, _ change: (inout AlertSetting) -> Void) {
        var setting = alert(kind)
        change(&setting)
        alerts[kind] = setting
    }

    func isEnabled(_ source: SessionSource) -> Bool {
        enabledSources.contains(source)
    }

    func setEnabled(_ source: SessionSource, _ enabled: Bool) {
        if enabled { enabledSources.insert(source) } else { enabledSources.remove(source) }
    }
}
