import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let preferences = Preferences()
    private let usage = UsageMonitor()
    private var statusItem: StatusItemController?
    private var panel: PanelController?
    private var notch: NotchController?
    private var server: EventServer?
    private var monitor: SessionMonitor?
    private let focusService = FocusService()
    private let promptService = PromptService()
    private var alerts: AlertCenter?
    private var settingsWindow: SettingsWindowController?
    private let installer = HookInstaller()
    private var sourceObservation: Task<Void, Never>?
    private var claudeUsageObservation: Task<Void, Never>?
    private var remote: RemoteHub?

    /// Unit tests run inside this app (TEST_HOST). Skip UI and server then.
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }
        // Dev aid: `-renderIconTo <dir>` writes the app icon PNGs and quits (scripts/make-icon.sh).
        if let directory = UserDefaults.standard.string(forKey: "renderIconTo") {
            do {
                try AppIconRenderer.render(to: URL(fileURLWithPath: directory))
            } catch {
                FileHandle.standardError.write(Data("Icon render failed: \(error)\n".utf8))
            }
            exit(0)
        }

        let monitor = SessionMonitor(store: store)
        monitor.autoHideDoneMinutes = { [preferences] in preferences.autoHideDoneMinutes }
        let alerts = AlertCenter(store: store, preferences: preferences)
        alerts.onOpenCard = { [weak self] id in self?.store.focus(id) }
        alerts.start()
        self.alerts = alerts
        let remote = RemoteHub(store: store)
        let approvals = ApprovalCenter()
        remote.approvals = approvals
        alerts.onAlert = { [weak remote] kind, session in remote?.broadcastAlert(kind, session: session) }
        remote.onPrompt = { [weak self] cardID, text in
            guard let self else { return "Agent Lounge is closing." }
            return promptService.send(text, to: store.session(cardID))
        }
        remote.start()
        self.remote = remote
        settingsWindow = SettingsWindowController(preferences: preferences, installer: installer, remote: remote) { [weak alerts] in
            alerts?.requestNotificationPermission()
        }
        observeSources()

        let router = EventRouter(store: store)
        router.onEventApplied = { [weak monitor] event, createdCard in
            monitor?.eventApplied(event, createdCard: createdCard)
        }
        router.onStateChange = { [weak alerts] event, before in
            alerts?.eventApplied(event, before: before)
        }
        router.hookStatus = { [installer] in
            Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { agent in
                (agent.rawValue, Self.hookStatusText(installer.status(agent)))
            })
        }
        router.remoteStatus = { [weak remote] in remote?.debugStatus ?? [:] }
        router.startPairing = { [weak remote] in
            guard let remote, remote.isEnabled else { return nil }
            return remote.startPairing().code
        }
        router.approvals = approvals
        let server = EventServer { request, responder in router.handle(request, responder: responder) }
        server.start(port: EventServer.configuredPort())
        monitor.start()
        self.server = server
        self.monitor = monitor

        usage.claudeEnabled = { [preferences] in preferences.showsUsage && preferences.claudeUsageEnabled }
        usage.start()
        remote.usage = usage

        let panel = PanelController(store: store, preferences: preferences, usage: usage)
        panel.onOpenSettings = { [weak self] in self?.showSettings() }
        let statusItem = StatusItemController(store: store)
        statusItem.onPrimaryClick = { [weak panel] in panel?.toggle() }
        statusItem.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        panel.anchorProvider = { [weak statusItem] in statusItem?.anchor }
        self.panel = panel
        self.statusItem = statusItem

        let notch = NotchController(store: store, preferences: preferences)
        notch.onOpenPanel = { [weak panel] in panel?.toggle() }
        notch.start()
        self.notch = notch

        store.focusHandler = { [weak self, weak panel] session in
            guard let self else { return }
            // An unpinned panel is a popover: close it so it does not cover the focused window.
            if !preferences.isPinned { panel?.close() }
            focusService.focus(session)
        }

        // Reopen a pinned panel. `-openPanelAtLaunch YES` is a dev shortcut.
        if preferences.isPinned || UserDefaults.standard.bool(forKey: "openPanelAtLaunch") {
            Task {
                // Wait until the status item has a frame on screen.
                try? await Task.sleep(for: .milliseconds(300))
                panel.show()
            }
        }
    }

    /// Keeps the store's source filter in sync with the settings.
    private func observeSources() {
        let preferences = preferences
        let store = store
        sourceObservation = Task {
            for await enabled in Observations({ preferences.enabledSources }) {
                store.disabledSources = Set(SessionSource.allCases).subtracting(enabled)
            }
        }
        // Read Claude usage at once when it is turned on.
        let usage = usage
        claudeUsageObservation = Task {
            for await _ in Observations({ preferences.showsUsage && preferences.claudeUsageEnabled }) {
                await usage.refreshClaude()
            }
        }
    }

    static func hookStatusText(_ status: Result<HookConfig.Status, Error>) -> String {
        switch status {
        case .success(.installed): "installed"
        case .success(.outdated): "outdated"
        case .success(.notInstalled): "not installed"
        case .failure(let error): "error: \(error.localizedDescription)"
        }
    }

    func showSettings() {
        settingsWindow?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        monitor?.stop()
        remote?.stop()
        usage.stop()
        notch?.stop()
    }

    // MARK: - Status item menu (right-click)

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let serverItem = NSMenuItem(title: serverStatusText, action: nil, keyEquivalent: "")
        serverItem.isEnabled = false
        menu.addItem(serverItem)
        let hooks = AgentKind.allCases.map { agent in
            "\(agent.label) \(Self.hookStatusText(installer.status(agent)))"
        }
        let hooksItem = NSMenuItem(title: "Hooks: " + hooks.joined(separator: " · "), action: #selector(openSettings), keyEquivalent: "")
        hooksItem.target = self
        hooksItem.toolTip = "Open Settings to install or update hooks."
        menu.addItem(hooksItem)
        menu.addItem(.separator())

        let pin = NSMenuItem(title: "Pin Panel", action: #selector(togglePin), keyEquivalent: "")
        pin.target = self
        pin.state = preferences.isPinned ? .on : .off
        menu.addItem(pin)

        let notchItem = NSMenuItem(title: "Show Notch Status", action: #selector(toggleNotch), keyEquivalent: "")
        notchItem.target = self
        notchItem.state = preferences.notchEnabled ? .on : .off
        menu.addItem(notchItem)

        let mute = NSMenuItem(title: "Mute Sounds", action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        mute.state = preferences.isMuted ? .on : .off
        menu.addItem(mute)

        menu.addItem(.separator())

        let trusted = AccessibilityWindows.isTrusted
        let accessibility = NSMenuItem(
            title: trusted ? "Accessibility Access Granted" : "Grant Accessibility Access…",
            action: trusted ? nil : #selector(grantAccessibility),
            keyEquivalent: ""
        )
        accessibility.target = self
        accessibility.isEnabled = !trusted
        accessibility.toolTip = "Used to raise Zed windows and restore minimized windows when you click ↗."
        menu.addItem(accessibility)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let mocks = NSMenuItem(title: "Add Mock Sessions", action: #selector(addMocks), keyEquivalent: "")
        mocks.target = self
        menu.addItem(mocks)

        menu.addItem(.separator())

        menu.addItem(
            NSMenuItem(title: "Quit Agent Lounge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )
        return menu
    }

    private var serverStatusText: String {
        switch server?.status ?? .stopped {
        case .stopped: "Event server stopped"
        case .starting(let port): "Starting on 127.0.0.1:\(port)…"
        case .listening(let port): "Listening on 127.0.0.1:\(port)"
        case .failed(let message): "Event server error: \(message)"
        }
    }

    @objc private func togglePin() { panel?.togglePin() }
    @objc private func toggleNotch() { preferences.notchEnabled.toggle() }
    @objc private func toggleMute() { preferences.isMuted.toggle() }
    @objc private func openSettings() { showSettings() }
    @objc private func addMocks() { store.addMockSessions() }
    @objc private func grantAccessibility() {
        if !AccessibilityWindows.requestTrust() { AccessibilityWindows.openSettings() }
    }
}
