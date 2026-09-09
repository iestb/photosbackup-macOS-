import SwiftUI

/// The original feasibility-probe interface, preserved for engineering and support.
struct DiagnosticsView: View {
    @EnvironmentObject private var log: ProbeLog
    @EnvironmentObject private var probe: AccountConnector
    @EnvironmentObject private var queue: UploadQueue
#if DEBUG
    @EnvironmentObject private var automaticBackup: AutomaticBackupCoordinator
#endif
    @State private var manualToken = ""
    @State private var showAdvanced = false
    @State private var showingConnect = false

    var body: some View {
        List {
            Section("Environment") {
                LabeledRow(PlatformVersion.name, value: PlatformVersion.version)
            }

#if DEBUG
            Section {
                // Say up front why a run would refuse, rather than making the
                // user press the button to find out.
                if let blocker = automaticBackup.scheduleBlocker {
                    Label(blocker, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Ready to run", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
                Button {
                    automaticBackup.simulateRun()
                } label: {
                    Label("Simulate Background Run", systemImage: "play.circle")
                }
                Text(automaticBackup.debugSimulationStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
#if os(iOS)
                Button("Copy LLDB Launch Command") {
                    Pasteboard.copy(AutomaticBackupCoordinator.lldbSimulationCommand)
                }
#endif
                Button("Copy Log Stream Command") {
                    Pasteboard.copy(AutomaticBackupCoordinator.logStreamCommand)
                }
            } header: {
                Text("Background Debugging")
            } footer: {
#if os(iOS)
                Text(AutomaticBackupCoordinator.lldbSimulationCommand)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
#else
                Text("\"Simulate Background Run\" calls the same backup pass macOS's periodic timer uses.")
#endif
            }
#endif

            if !queue.recentFailures.isEmpty {
                Section {
                    ForEach(queue.recentFailures) { failure in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(failure.name).font(.caption.weight(.medium)).lineLimit(1)
                                Spacer()
                                if let code = failure.statusCode {
                                    Text("code \(code)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                            Text(failure.reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                    Button("Copy All Failures") {
                        Pasteboard.copy(queue.recentFailures
                            .map(\.summary)
                            .joined(separator: "\n"))
                    }
                } header: {
                    Text("Upload Failures")
                } footer: {
                    // The count is the part a bug report never has: one 400 and
                    // four hundred of them read identically on a cleared queue.
                    Text(queue.failureCount > queue.recentFailures.count
                         ? "\(queue.failureCount) failures this session; showing the \(queue.recentFailures.count) most recent."
                         : "\(queue.failureCount) failures this session.")
                }
            }

            Section("Connection Flow") {
                Button { showingConnect = true } label: {
                    Label("Connect Google Account", systemImage: "person.badge.key")
                }
                if probe.running { HStack { ProgressView(); Text("Running exchange…").foregroundStyle(.secondary) } }
            }

            Section("Feasibility Checklist") {
                ForEach(log.steps) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Image(systemName: item.state.symbol).foregroundStyle(item.state.tint)
                            Text(item.title)
                            Spacer()
                        }
                        if !item.detail.isEmpty {
                            Text(item.detail).font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if probe.lastResult != nil {
                Section {
                    Button("Re-run Read-only Check") { Task { await probe.rerunReadAccess() } }.disabled(probe.running)
                }
            }

            Section {
                DisclosureGroup("Advanced: Paste oauth_token", isExpanded: $showAdvanced) {
                    TextField("oauth_token value", text: $manualToken)
                        .noAutocapitalizationCompat().autocorrectionDisabled().font(.footnote.monospaced()).lineLimit(4)
                    Button("Run Exchange") {
                        let token = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !token.isEmpty else { return }
                        log.set(ProbeLog.cookieRead, .skipped, "manual paste")
                        log.set(ProbeLog.nativeHandoff, .skipped, "manual paste")
                        log.set(ProbeLog.appIngest, .skipped, "manual paste")
                        Task { await probe.runExchange(oauthToken: token) }
                    }
                    .disabled(manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || probe.running)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .inlineNavigationTitleCompat()
        .fullScreenCoverCompat(isPresented: $showingConnect) {
            AccountConnectView(
                onCaptured: { token in
                    showingConnect = false
                    Task { await probe.ingestWebToken(token) }
                },
                onCancel: { showingConnect = false }
            )
        }
    }
}
