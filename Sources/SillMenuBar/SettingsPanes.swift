import AppKit
import Combine
import SwiftUI
import SillHostCore
import StreamProtocol

/// One user-facing settings tab, with native controls bound to the app models.
struct SettingsPane: View {
    let tab: SettingsTab
    let model: AppModel

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralPane(model: model)
            case .tablet: SidecarTabletPane(tablet: model.tablet, permissions: model.permissions)
            case .devices: LiveDevicesPane(model: model, settings: model.settings)
            case .streaming: StreamingPane(model: model, settings: model.settings)
            case .virtualDisplay: VirtualDisplayPane(model: model, settings: model.settings)
            case .permissions: PermissionsPane(model: model)
            case .remoteAccess: LiveRemoteAccessPane(model: model, settings: model.settings)
            }
        }
        .formStyle(.grouped)
        .frame(width: tab == .tablet ? 700 : 520)
        // Permissions and the login item change behind HitPad's back, in System Settings. Re-read
        // them once a second, only while this tab is on screen, and when HitPad becomes active; an
        // idle HitPad with Settings closed wakes for nothing. The Devices and Remote Access panes
        // follow the host's status, which is pushed, so they poll nothing.
        .task(id: model.visibleSettingsTab == tab) {
            guard model.visibleSettingsTab == tab, tab != .streaming, tab != .devices, tab != .remoteAccess else { return }
            while !Task.isCancelled {
                model.permissions.refresh()
                model.loginItem.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.permissions.refresh()
            model.loginItem.refresh()
        }
    }
}

/// Footer text the way System Settings sets it: small, secondary, from the leading edge.
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An orange problem line with its sign.
struct Warning: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A system error message inside a sentence of ours: without its own full stop.
func withoutFullStop(_ text: String) -> String {
    text.hasSuffix(".") ? String(text.dropLast()) : text
}

// MARK: General

private struct GeneralPane: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { model.loginItem.isOn }, set: { model.loginItem.set($0) }))
                    .disabled(!model.loginItem.available)
                if !model.loginItem.available {
                    Footnote("Launch at login is available when this app runs from its app bundle.")
                } else if model.loginItem.needsApproval {
                    LabeledContent("Waiting for your approval") {
                        Button("Approve in System Settings…") { model.loginItem.openSystemSettings() }
                    }
                }
                if let error = model.loginItem.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            } footer: {
                Footnote("Open the tablet configurator when you sign in to your Mac.")
            }
            Section {
                LabeledContent("App") { Text("iPad as Tablet") }
                LabeledContent("Version") { Text("\(AppModel.version) (\(AppModel.build))").monospacedDigit() }
            } footer: {
                Footnote("Sidecar connects your iPad directly to your Mac. No companion app is needed.")
            }
        }
    }
}

// MARK: Clipboard

/// Share clipboard with devices (HostClipboard, docs/clipboard-plan.md): the switch and its footnote,
/// and while the switch is on and macOS does not allow every read HitPad makes on its own
/// (ClipboardPolicy.MacAccess), why what is copied here stays on this Mac and the way to allow it.
/// Drawn alone in the previews in each of macOS's answers (DebugHooks).
struct ClipboardSection: View {
    @Binding var shareClipboard: Bool
    let access: ClipboardPolicy.MacAccess
    var allow: () -> Void = {}

    var body: some View {
        Section {
            Toggle("Share clipboard with devices", isOn: $shareClipboard)
            if shareClipboard, let warning = ClipboardPolicy.Copy.macAccessWarning(access) {
                VStack(alignment: .leading, spacing: 6) {
                    Warning(warning)
                    if let hint = ClipboardPolicy.Copy.macAccessHint(access) {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(ClipboardPolicy.Copy.macAccessButton, action: allow)
                }
            }
        } footer: {
            Footnote(ClipboardPolicy.Copy.macFootnote)
        }
    }
}

// MARK: Updates

/// Settings › General's update check: the automatic switch, the line (what the last check found, or
/// why HitPad cannot check), Open Release Page… while a newer release is offered, and Check Now. Plain
/// values in, so the previews draw every state. Errors show here and in the log, never in an alert.
struct UpdatesSection: View {
    struct Actions {
        var checkNow: () -> Void = {}
        var openRelease: (URL) -> Void = { _ in }
    }

    let pane: UpdatePolicy.Pane
    @Binding var automatic: Bool
    var actions = Actions()

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $automatic)
            LabeledContent {
                HStack(spacing: 8) {
                    if let url = pane.releasePage {
                        Button("Open Release Page…") { actions.openRelease(url) }
                    }
                    Button("Check Now") { actions.checkNow() }
                        .disabled(!pane.canCheck)
                }
            } label: {
                Text(pane.line)
                    .foregroundStyle(pane.failed ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // VoiceOver hears Check Now's result, which arrives after the click.
            .onChange(of: pane.resultID) { _, _ in
                AccessibilityNotification.Announcement(pane.line).post()
            }
        } footer: {
            Footnote(UpdatePolicy.footnote)
        }
    }
}

// MARK: Streaming

private struct StreamingPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings

    var body: some View {
        Form {
            Section {
                Picker("Frame rate limit", selection: $settings.config.maxFPS) {
                    Text("60 fps").tag(60)
                    Text("120 fps").tag(120)
                }
                .pickerStyle(.segmented)
                Picker("Quality", selection: $settings.config.bitrate) {
                    ForEach(QualityPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    if QualityPreset(rawValue: settings.config.bitrate) == nil {
                        Text(QualityPreset.title(forBitrate: settings.config.bitrate)).tag(settings.config.bitrate)
                    }
                }
                Picker("Resolution", selection: $settings.config.captureScale) {
                    Text("Retina").tag(CGFloat(2))
                    Text("Standard").tag(CGFloat(1))
                }
            } footer: {
                Footnote("Each device asks for its own screen’s rate, up to this limit. Quality is per 60 fps; a 120 fps stream gets twice as much. \(QualityPreset.fastLinkNote) Changes apply at once: the current stream restarts for a moment.")
            }
            // Away from home (docs/remote-bundle-plan.md §5): its own quality, which a device away
            // sets too; the menu's Quality and Resolution stay the home ones.
            Section {
                Picker("Quality", selection: $settings.config.awayBitrate) {
                    ForEach(QualityPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    if QualityPreset(rawValue: settings.config.awayBitrate) == nil {
                        Text(QualityPreset.title(forBitrate: settings.config.awayBitrate)).tag(settings.config.awayBitrate)
                    }
                }
                Picker("Resolution", selection: $settings.config.awayCaptureScale) {
                    Text("Retina").tag(CGFloat(2))
                    Text("Standard").tag(CGFloat(1))
                }
            } header: {
                Text("Away from home")
            } footer: {
                Footnote("HitPad streams at these while every connected device is away from home, through a VPN or over the internet, so a slow connection never starts at your home quality. A device away from home changes these, and never your Quality and Resolution above."
                         + (model.coordinator?.status.snapshot.away == true ? " Streaming at these now." : ""))
            }
            Section {
                Toggle("Prioritize encoding speed", isOn: $settings.config.prioritizeSpeed)
            } footer: {
                Footnote("Lower latency when the Mac is busy, at a softer picture.")
            }
            // The Mac's sound (docs/audio-plan.md §6), a beta: its switch and its footnote say so, and
            // only this Mac turns it on (Q8).
            Section {
                Toggle("Send audio (beta)", isOn: $settings.config.sendAudio)
                if settings.config.sendAudio, let problem = model.coordinator?.status.snapshot.audio?.problem {
                    Warning("HitPad \(problem). The picture is unaffected.")
                }
            } footer: {
                Footnote("Beta. Devices play the sound of what you stream: all of the streamed window’s app, or every app for the Desktop. The Mac keeps playing it too, and each device can mute it with its Sound button. Only this Mac turns it on. Nothing is recorded.")
            }
            if let snapshot = model.coordinator?.status.snapshot, snapshot.softwareEncoder {
                Section {
                    Label(snapshot.hardwareEncoderStuck
                          ? "The hardware encoder is stuck, so streams use the software encoder: up to 60 fps at Standard resolution. Restarting the Mac fixes this."
                          : "The hardware encoder is busy or not answering, so streams use the software encoder: up to 60 fps at Standard resolution. HitPad switches back by itself once it keeps up again.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: Virtual Display

private struct VirtualDisplayPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings
    @State private var retrying = false

    var body: some View {
        let snapshot = model.coordinator?.status.snapshot ?? HostStatusSnapshot()
        Form {
            Section {
                Toggle("Stream from a virtual display", isOn: $settings.config.virtualDisplay)
            } footer: {
                Footnote("HitPad moves the window you pick onto an invisible display made for your device, so it keeps updating when other windows cover it and text is drawn at your device’s scale. The window leaves this screen while it streams and comes back when you stop streaming or quit HitPad.")
            }
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Text(statusText(snapshot))
                            .multilineTextAlignment(.trailing)
                        if canRetry(snapshot) {
                            Button("Try Again") {
                                retrying = true
                                Task { @MainActor in
                                    await model.coordinator?.retryVirtualDisplay()
                                    retrying = false
                                }
                            }
                            .disabled(retrying || model.coordinator == nil)
                        }
                    }
                }
                if settings.config.virtualDisplay, let failure = snapshot.lastStageFailure {
                    LabeledContent("Last window") {
                        Text("Streamed where it is: \(failure)").multilineTextAlignment(.trailing)
                    }
                }
            } footer: {
                Footnote("Uses a private macOS interface (CGVirtualDisplay). If a macOS update breaks it, HitPad streams the window where it is.")
            }
        }
    }

    private func statusText(_ s: HostStatusSnapshot) -> String {
        let sr = model.permissions.screenRecording, ax = model.permissions.accessibility
        if s.virtualDisplayAPIMissing, let problem = s.virtualDisplayProblem {
            return "Not available on this version of macOS: \(problem)"
        }
        if !sr && !ax { return "Needs Screen Recording and Accessibility" }
        if !ax { return "Needs Accessibility" }
        if !sr { return "Needs Screen Recording" }
        if let problem = s.virtualDisplayProblem { return "Off for this session: \(problem)" }
        return "Available"
    }

    /// A run-level disable (the system removed the display too often) can be retried; a missing
    /// API or permission cannot.
    private func canRetry(_ s: HostStatusSnapshot) -> Bool {
        s.virtualDisplayProblem != nil && !s.virtualDisplayAPIMissing && model.permissions.allGranted
    }
}

// MARK: Permissions

private struct PermissionsPane: View {
    let model: AppModel

    var body: some View {
        let permissions = model.permissions
        let network = model.coordinator?.status.snapshot.network
        Form {
            Section {
                PermissionRow(title: "Screen Recording", allowed: permissions.screenRecording,
                              // Not "on this network": a device connected over Direct Wireless shares none.
                              explanation: "Lets HitPad capture the windows you pick on your iPhone or iPad, and their sound when Send Audio is on. Nothing is recorded or saved; frames and sound go straight to your devices.",
                              button: model.settings.askedScreenRecording ? "Open System Settings…" : "Allow…") {
                    permissions.requestScreenRecording()
                }
                PermissionRow(title: "Accessibility", allowed: permissions.accessibility,
                              explanation: "Lets your iPhone or iPad click, scroll and type on this Mac, and lets HitPad move and size the window it streams.",
                              button: model.settings.askedAccessibility ? "Open System Settings…" : "Allow…") {
                    permissions.requestAccessibility()
                }
            } footer: {
                Footnote("Access belongs to HitPad itself. Access you gave Terminal for the separate command-line host doesn’t carry over.")
            }
            if permissions.relaunchSuggested, !permissions.screenRecording {
                Section {
                    LabeledContent("Screen Recording starts working once HitPad opens again.") {
                        Button(permissions.canRelaunch ? "Relaunch HitPad" : "Quit HitPad") { permissions.relaunch() }
                    }
                }
            }
            if Self.networkNeedsHelp(network) {
                Section {
                    LabeledContent {
                        Button("Open Local Network…") { permissions.openPrivacyPane("Privacy_LocalNetwork") }
                    } label: {
                        Text("Local Network")
                        Text("If your iPhone or iPad can’t find this Mac, allow HitPad in Privacy & Security › Local Network.")
                    }
                }
            }
            if permissions.allGranted {
                Section {
                    Label("You’re all set. Open HitPad on your iPhone or iPad.", systemImage: "checkmark.seal.fill")
                }
            }
        }
    }

    private static func networkNeedsHelp(_ network: HostStatusSnapshot.Network?) -> Bool {
        switch network {
        case .waiting, .failed: return true
        default: return false
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let allowed: Bool
    let explanation: String
    let button: String
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if allowed {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button(button, action: action)
                }
            }
        } label: {
            Text(title)
            Text(explanation)
        }
    }
}
