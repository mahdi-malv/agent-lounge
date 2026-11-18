import SwiftUI

/// Settings section: phone access on the local network (PLAN M8).
struct PhoneSection: View {
    let remote: RemoteHub

    @State private var removing: PairedDevice?

    var body: some View {
        Section {
            Toggle("Allow the phone app on this network", isOn: Binding(
                get: { remote.isEnabled },
                set: { remote.setEnabled($0) }
            ))
            if remote.isEnabled {
                LabeledContent("Status") {
                    Text(statusText)
                        .foregroundStyle(isFailed ? .red : .secondary)
                        .textSelection(.enabled)
                }
                Toggle(isOn: Binding(
                    get: { remote.approvalsEnabled },
                    set: { remote.setApprovalsEnabled($0) }
                )) {
                    Text("Phones can answer permission requests")
                    Text("Claude Code only. The dialog on the Mac stays usable.")
                }
                pairingRow
                ForEach(remote.book.devices) { device in
                    deviceRow(device)
                }
            }
        } header: {
            Text("Phone")
        } footer: {
            Text("Paired phones see card titles, folders, activity and last messages, and can answer permission requests when allowed above. The connection is encrypted. Pair only on a network you trust: the code protects the pairing against listening, not against an active attacker.")
                .foregroundStyle(.secondary)
        }
        .alert(item: $removing) { device in
            Alert(
                title: Text("Remove \(device.name)?"),
                message: Text("The phone must pair again to connect."),
                primaryButton: .destructive(Text("Remove")) { remote.removeDevice(device.id) },
                secondaryButton: .cancel()
            )
        }
    }

    @ViewBuilder
    private var pairingRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let pairing = remote.activePairing(now: context.date) {
                LabeledContent {
                    HStack(spacing: 12) {
                        Text(Self.grouped(pairing.code))
                            .font(.system(.title2, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                            .accessibilityLabel("Pairing code \(pairing.code.map(String.init).joined(separator: " "))")
                        Text(Self.remaining(pairing.expiresAt.timeIntervalSince(context.date)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Cancel") { remote.cancelPairing() }
                    }
                } label: {
                    Text("Code")
                    Text("Enter it in the phone app.")
                }
            } else {
                LabeledContent {
                    Button("Pair a Phone…") { remote.startPairing() }
                        .disabled(!isListening)
                } label: {
                    Text("Pairing")
                    Text("Shows a code for 5 minutes.")
                }
            }
        }
    }

    private func deviceRow(_ device: PairedDevice) -> some View {
        LabeledContent {
            Button("Remove…") { removing = device }
        } label: {
            Label(device.name, systemImage: "iphone.gen3")
            Text(deviceDetail(device))
        }
    }

    private func deviceDetail(_ device: PairedDevice) -> String {
        if remote.connectedDeviceIDs.contains(device.id) { return "Connected" }
        guard let lastSeen = device.lastSeenAt else { return "Not connected" }
        return "Last seen " + lastSeen.formatted(.relative(presentation: .named))
    }

    private var isListening: Bool {
        if case .listening = remote.status { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = remote.status { return true }
        return false
    }

    private var statusText: String {
        switch remote.status {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .failed(let message): return message
        case .listening(let port):
            let addresses = remote.lanAddresses.map { "\($0):\(port)" }
            let where_ = addresses.isEmpty ? "port \(port)" : addresses.joined(separator: ", ")
            return "“\(remote.serviceName)” on \(where_)"
        }
    }

    private static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    private static func remaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
