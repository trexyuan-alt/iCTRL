import SwiftUI
import UIKit

/// The app's home screen.
///
/// Production control uses the ZERO-XCTEST Companion hosted by this normal app.
/// The Companion serves only authenticated bootstrap/authority RPC. UI reads and
/// actions remain on CoreDevice / RemotePairing / RSD / remoteAX / UniversalHID.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    /// Re-probed whenever the view appears rather than held in AppState: the DDI
    /// can be unmounted while the app sits in the background, so a value cached
    /// at launch goes stale silently.
    @State private var ddi = DeveloperDiskImage.status()
    @State private var showMountSheet = false
    @StateObject private var runner = RunnerStatus(port: 8200)
    @EnvironmentObject private var runnerAdmin: RunnerAdmin
    @State private var logCount = AppLog.allFiles().count


    /// Provides the local loopback tunnel StikDebug needs to reach lockdownd.
    /// Deliberately an App Store link and not a deep link: neither LocalDevVPN
    /// nor its predecessor StosVPN registers a URL scheme, so any
    /// `localdevvpn://` we invented would fail silently. StosVPN has also been
    /// pulled from the App Store, which is why LocalDevVPN is the one named here.
    private static let localDevVPNURL = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!

    /// StikDebug mounts the DDI on-device. It registers both `stikdebug://` and
    /// the legacy `stikjit://`; bare scheme just opens the app.
    private static let stikDebugURL = URL(string: "stikdebug://")!
    /// Used when StikDebug isn't installed — it's sideload-only, never on the
    /// App Store, so the fallback is its distribution site.
    private static let stikDebugSiteURL = URL(string: "https://stikdebug.xyz")!

    var body: some View {
        List {
            requirementsSection

            // Fallback only. The in-app mount above does the same job without
            // leaving iCTRL; StikDebug stays listed because it is the
            // battle-tested implementation this port is based on, and is worth
            // trying if our mount fails on a device we haven't seen.
            if !ddi.isMounted {
                Section {
                    HelperRow(
                        index: 1,
                        title: "LocalDevVPN",
                        detail: "Required either way — it makes this device's debug service reachable.",
                        actionTitle: "App Store",
                        url: Self.localDevVPNURL
                    )
                    HelperRow(
                        index: 2,
                        title: "StikDebug",
                        detail: "An alternative mounter, if the in-app one fails. Sideload from stikdebug.xyz — it isn't on the App Store.",
                        actionTitle: "Open",
                        url: Self.stikDebugURL,
                        fallbackURL: Self.stikDebugSiteURL
                    )
                } header: {
                    Text(L10n.t(.alternativeSection))
                } footer: {
                    Text(L10n.t(.alternativeFooter))
                }
            }

            serverSection

            deviceSection

            Section {
                HStack {
                    Text(L10n.t(.versionLabel))
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text(L10n.t(.protocolLabel))
                    Spacer()
                    Text("JSON-RPC 2.0")
                        .foregroundColor(.secondary)
                }
                NavigationLink {
                    LogListView()
                } label: {
                    HStack {
                        Text(L10n.t(.logsLabel))
                        Spacer()
                        Text(verbatim: "\(logCount)")
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text(L10n.t(.aboutSection))
            } footer: {
                // The mount runs through a Rust FFI that aborts rather than
                // throws, so when it fails the log is often the only artifact
                // besides a crash report — and it can be shared from here.
                Text(L10n.t(.logsFooter))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("iCTRL")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ddi = DeveloperDiskImage.status()
            logCount = AppLog.allFiles().count
            runner.startPolling()
        }
        .onDisappear { runner.stopPolling() }
        .sheet(isPresented: $showMountSheet, onDismiss: {
            // Re-probe: a successful mount changes what the status row should say.
            ddi = DeveloperDiskImage.status()
        }) {
            DDIMountView()
        }
    }

    /// What must be true before the CoreDevice control chain can be prepared.
    ///
    /// The Developer Disk Image remains the hard prerequisite for the
    /// RemotePairing/CoreDevice path. The Companion itself is a normal app and
    /// does not start XCTest or testmanagerd UI automation.
    private var requirementsSection: some View {
        Section {
            HStack {
                Text(L10n.t(.developerDiskImage))
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(ddi.isMounted ? .green : .orange)
                        .frame(width: 8, height: 8)
                    Text(ddi.summary)
                        .foregroundColor(.secondary)
                }
            }

            if let layout = ddi.layout {
                HStack {
                    Text(L10n.t(.mountPoint))
                    Spacer()
                    Text(layout.rawValue)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            // Offered in both states. Mounted is not the same as "nothing left
            // to do": the image is dropped by a reboot, and a stale or partial
            // mount looks identical from here, so re-mounting has to stay one
            // tap away rather than something you can only reach by rebooting.
            Button {
                showMountSheet = true
            } label: {
                Label(ddi.isMounted ? L10n.t(.remount) : L10n.t(.mountWithoutMac),
                      systemImage: ddi.isMounted ? "arrow.clockwise" : "externaldrive.badge.plus")
            }
        } header: {
            Text(L10n.t(.runtimeRequirements))
        } footer: {
            if ddi.isMounted {
                Text(L10n.t(.ddiReadyFooter))
            } else {
                Text(ddi.advice ?? "The Developer Disk Image isn't mounted, so the CoreDevice control chain can't be prepared.")
            }
        }
    }

    /// This device, read locally.
    ///
    /// Deliberately not sourced from the server's device_info: these values are
    /// available whether or not the runner is up, and they're most useful
    /// precisely when it isn't — "which iOS is this?" is the first question
    /// asked when the runner won't start.
    private var deviceSection: some View {
        Section {
            LabeledRow(L10n.t(.modelLabel), DeviceInfo.modelIdentifier)
            LabeledRow(L10n.t(.systemLabel), "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
            LabeledRow(L10n.t(.screenLabel), DeviceInfo.screenDescription)
            LabeledRow(L10n.t(.nameLabel), UIDevice.current.name, monospaced: false)
        } header: {
            Text(L10n.t(.deviceSection))
        }
    }

    /// Live state of the ZERO-XCTEST Companion service.
    ///
    /// The HTTP probe remains authoritative so it verifies the exact :8200
    /// surface the backend will use, rather than trusting only local UI state.
    private var serverSection: some View {
        Section {
            HStack {
                Text(L10n.t(.statusLabel))
                Spacer()
                switch runner.state {
                case .unknown, .checking:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.t(.checking)).foregroundColor(.secondary)
                    }
                case .running:
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text(L10n.t(.running)).foregroundColor(.secondary)
                    }
                case .stopped:
                    HStack(spacing: 6) {
                        Circle().fill(.secondary).frame(width: 8, height: 8)
                        Text(L10n.t(.stopped)).foregroundColor(.secondary)
                    }
                }
            }

            HStack {
                Text(L10n.t(.addressLabel))
                Spacer()
                Text(verbatim: "127.0.0.1:\(appState.serverPort)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if case .running(let info) = runner.state {
                if let version = info.serverVersion {
                    HStack {
                        Text(L10n.t(.serverLabel))
                        Spacer()
                        Text(verbatim: version)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                if let proto = info.protocolVersion {
                    HStack {
                        Text(L10n.t(.protocolLabel))
                        Spacer()
                        Text(verbatim: "v\(proto)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                if let methods = info.methodCount {
                    HStack {
                        Text(L10n.t(.methodsLabel))
                        Spacer()
                        Text(verbatim: "\(methods)")
                            .foregroundColor(.secondary)
                    }
                }
                if !info.capabilities.isEmpty {
                    NavigationLink {
                        CapabilityListView(capabilities: info.capabilities)
                    } label: {
                        HStack {
                            Text(L10n.t(.capabilitiesLabel))
                            Spacer()
                            Text(verbatim: "\(info.capabilities.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                if let visibility = runnerAdmin.visibility {
                    RunnerVisibilityRow(visibility: visibility)
                }
                if runnerAdmin.localNetworkDenied {
                    // Remote clients connecting in still work without it, so
                    // this is the only sign of why nearby discovery cannot.
                    Text(L10n.t(.runnerLocalNetworkDenied))
                        .font(.footnote)
                        .foregroundColor(.orange)
                }
                NavigationLink {
                    RunnerClientsView()
                } label: {
                    HStack {
                        Text(L10n.t(.authorizedClients))
                        Spacer()
                        if runnerAdmin.clientsLoaded {
                            Text(verbatim: "\(runnerAdmin.clients.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                // Count and visibility without opening the list, kept current
                // while this screen is shown (remote access and nearby can be
                // switched from the runner's notification at any time). Only
                // once paired: pairing itself is never started from here.
                .task(id: runnerAdmin.isPaired) {
                    while !Task.isCancelled && runnerAdmin.isPaired {
                        await runnerAdmin.loadClients()
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                    }
                }
                NavigationLink {
                    RunnerLogsView()
                } label: {
                    Text(L10n.t(.runnerLogs))
                }
                Button(role: .destructive) {
                    stopCompanion()
                } label: {
                    Label(L10n.t(.stopServerButton), systemImage: "stop.fill")
                }
            } else {
                // Start lives here rather than in the toolbar: it belongs beside
                // the state it changes, and this is where the reason it might be
                // disabled is already on screen.
                Button {
                    startCompanion()
                } label: {
                    Label(L10n.t(.startServer), systemImage: "play.fill")
                }
                .disabled(appState.ownerControlBusy)
            }
        } header: {
            Text(L10n.t(.serverSectionTitle))
        } footer: {
            if case .running = runner.state {
                Text("\(L10n.t(.addressLabel)): \(appState.serverPort) · \(L10n.t(.serverRunningFooter))")
            } else if !ddi.isMounted {
                Text(L10n.t(.mountFirstFooter))
            } else {
                Text(L10n.t(.startOpensRunnerFooter))
            }
        }
    }

    private func stopCompanion() {
        // Local Companion lifecycle only. This never changes Owner authority.
        appState.stopServer()
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await runner.check()
        }
    }

    private func startCompanion() {
        // "Start Service" controls only the normal ZERO-XCTEST Companion
        // listener. It never creates Owner authority.
        appState.startServer()
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await runner.check()
        }
    }
}

/// One numbered step in the "mount without a Mac" recovery flow.
private struct HelperRow: View {
    let index: Int
    let title: String
    let detail: String
    /// `nil` for a step the user performs here rather than in another app.
    let actionTitle: String?
    let url: URL?
    /// Opened when `url` uses a custom scheme and the app isn't installed.
    var fallbackURL: URL? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(index)")
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.tint))

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let actionTitle, let url {
                Button(actionTitle) { open(url) }
                    .font(.caption.weight(.semibold))
                    // Rows sit in a List; .borderless keeps the tap on the button
                    // instead of letting the whole row swallow it.
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private func open(_ url: URL) {
        UIApplication.shared.open(url) { ok in
            // A custom-scheme open fails when that app isn't installed; falling
            // back to its download page turns a dead tap into a way forward.
            guard !ok, let fallbackURL else { return }
            UIApplication.shared.open(fallbackURL)
        }
    }
}

/// The capability tags the running server advertises.
///
/// A flat list rather than a summary: these are what a client feature-detects
/// against, so the useful question is "is X there", which a searchable list
/// answers and a count does not.
private struct CapabilityListView: View {
    let capabilities: [String]

    var body: some View {
        List(capabilities.sorted(), id: \.self) { tag in
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                Text(verbatim: tag)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .navigationTitle("Capabilities")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A right-aligned value row, the shape the rest of this screen already uses.
private struct LabeledRow: View {
    let label: String
    let value: String
    var monospaced = true

    init(_ label: String, _ value: String, monospaced: Bool = true) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(verbatim: value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Facts about this device that don't need the server running.
enum DeviceInfo {
    /// e.g. "iPhone17,2". `UIDevice.model` only ever says "iPhone", which
    /// doesn't distinguish the hardware people actually care about here.
    static var modelIdentifier: String {
        // On the simulator `utsname.machine` reports the *host* architecture
        // ("arm64"), not a device model — the real identifier is passed in the
        // environment instead. Without this the row reads "arm64", which is
        // both wrong and confusing next to a real device's "iPhone17,2".
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var sysinfo = utsname()
        uname(&sysinfo)
        let raw = withUnsafeBytes(of: &sysinfo.machine) { buf in
            buf.prefix { $0 != 0 }.map { UInt8($0) }
        }
        let id = String(decoding: raw, as: UTF8.self)
        return id.isEmpty ? UIDevice.current.model : id
    }

    /// Points and pixels — the two coordinate spaces the automation API mixes,
    /// so seeing both here saves a round trip when a screenshot looks wrong.
    static var screenDescription: String {
        let b = UIScreen.main.bounds
        let s = UIScreen.main.scale
        return "\(Int(b.width))×\(Int(b.height)) pt · \(Int(b.width * s))×\(Int(b.height * s)) px"
    }
}
