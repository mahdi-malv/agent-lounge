import AppKit
import SwiftUI
import UserNotifications

/// Settings window content (PLAN §6).
struct SettingsView: View {
    @Bindable var preferences: Preferences
    let installer: HookInstaller
    let remote: RemoteHub
    /// Asks for notification permission (AlertCenter).
    var requestNotifications: () -> Void

    var body: some View {
        Form {
            HooksSection(installer: installer)
            AlertsSection(preferences: preferences, requestNotifications: requestNotifications)
            PanelSection(preferences: preferences)
            SourcesSection(preferences: preferences)
            PhoneSection(remote: remote)
            GeneralSection()
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
    }
}

// MARK: - Alerts

private struct AlertsSection: View {
    @Bindable var preferences: Preferences
    var requestNotifications: () -> Void

    @State private var notificationStatus: UNAuthorizationStatus?
    private let soundNames = AlertCenter.systemSoundNames

    var body: some View {
        Section {
            Toggle("Mute all sounds", isOn: $preferences.isMuted)
            ForEach(AlertKind.allCases, id: \.self) { kind in
                AlertRow(kind: kind, preferences: preferences, soundNames: soundNames) { showsNotification in
                    if showsNotification { askForNotifications() }
                }
            }
            if notificationStatus == .denied {
                HStack {
                    Label("Notifications are off for Agent Lounge in System Settings.", systemImage: "bell.slash")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open…") { openNotificationSettings() }
                }
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text("Mute stops sounds only. Notifications still show. A click on a notification shows the agent's window.")
                .foregroundStyle(.secondary)
        }
        .task { await refreshStatus() }
    }

    private func askForNotifications() {
        requestNotifications()
        Task {
            try? await Task.sleep(for: .seconds(1))
            await refreshStatus()
        }
    }

    private func refreshStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct AlertRow: View {
    let kind: AlertKind
    let preferences: Preferences
    let soundNames: [String]
    var onNotificationChange: (Bool) -> Void

    var body: some View {
        let setting = preferences.alert(kind)
        LabeledContent {
            HStack(spacing: 8) {
                Toggle("Sound", isOn: binding(\.playsSound))
                    .toggleStyle(.checkbox)
                Picker("Sound", selection: binding(\.soundName)) {
                    ForEach(soundNames, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                .disabled(!setting.playsSound)
                Button {
                    AlertCenter.play(setting.soundName)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Play sound")
                .accessibilityLabel("Play \(setting.soundName)")
                Toggle("Notify", isOn: Binding(
                    get: { preferences.alert(kind).showsNotification },
                    set: { value in
                        preferences.setAlert(kind) { $0.showsNotification = value }
                        onNotificationChange(value)
                    }
                ))
                .toggleStyle(.checkbox)
            }
        } label: {
            Label(kind.label, systemImage: kind.systemImage)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AlertSetting, Value>) -> Binding<Value> {
        Binding(
            get: { preferences.alert(kind)[keyPath: keyPath] },
            set: { value in
                preferences.setAlert(kind) { $0[keyPath: keyPath] = value }
                if keyPath == \AlertSetting.soundName, let name = value as? String {
                    AlertCenter.play(name)
                }
            }
        )
    }
}

private extension AlertKind {
    var systemImage: String {
        switch self {
        case .needsInput: "exclamationmark.bubble"
        case .done: "checkmark.circle"
        case .error: "xmark.octagon"
        }
    }
}

// MARK: - Panel

private struct PanelSection: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Section("Panel") {
            Toggle("Pinned panel stays on top of other windows", isOn: $preferences.floatsWhenPinned)
            Picker("Hide done cards after", selection: $preferences.autoHideDoneMinutes) {
                ForEach(Preferences.autoHideChoices, id: \.self) { minutes in
                    Text(Self.label(minutes)).tag(minutes)
                }
            }
        }
    }

    private static func label(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Never"
        case 60: "1 hour"
        case let m where m > 60 && m % 60 == 0: "\(m / 60) hours"
        default: "\(minutes) minutes"
        }
    }
}

// MARK: - Sources

private struct SourcesSection: View {
    let preferences: Preferences

    var body: some View {
        Section {
            ForEach(SessionSource.allCases, id: \.self) { source in
                Toggle(source.label, isOn: Binding(
                    get: { preferences.isEnabled(source) },
                    set: { preferences.setEnabled(source, $0) }
                ))
            }
        } header: {
            Text("Sources")
        } footer: {
            Text("Turned-off sources are not shown and do not alert. Their hooks stay installed.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - General

private struct GeneralSection: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var needsApproval = LaunchAtLogin.needsApproval
    @State private var errorText: String?

    var body: some View {
        Section("General") {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { value in
                    errorText = LaunchAtLogin.set(value)
                    refresh()
                }
            ))
            if needsApproval {
                HStack {
                    Text("Allow Agent Lounge in Login Items.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open…") { LaunchAtLogin.openLoginItemsSettings() }
                }
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        launchAtLogin = LaunchAtLogin.isEnabled
        needsApproval = LaunchAtLogin.needsApproval
    }
}
