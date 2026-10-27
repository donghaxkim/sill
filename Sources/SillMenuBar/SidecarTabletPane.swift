import AppKit
import SwiftUI

struct SidecarTabletPane: View {
    @Bindable var tablet: SidecarTabletModel
    @Bindable var permissions: PermissionsModel

    var body: some View {
        Form {
            Section {
                Picker("iPad", selection: $tablet.selectedDeviceName) {
                    Text("Choose an iPad").tag("")
                    ForEach(tablet.devices) { device in
                        Text(device.name).tag(device.name)
                    }
                }
                .disabled(tablet.devices.isEmpty || tablet.isConnecting || tablet.isConnected)

                LabeledContent("Status") {
                    Text(tablet.statusText)
                        .foregroundStyle(tablet.isConnected ? .primary : .secondary)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Button(tablet.isConnected ? "Disconnect" : "Connect as Tablet") {
                        if tablet.isConnected { tablet.disconnect() }
                        else { tablet.connectSelected() }
                    }
                    .disabled(!tablet.isConnected && !tablet.canConnect)

                    Button("Refresh") { tablet.refreshDevices() }
                        .disabled(tablet.isConnecting)
                }

                if let problem = tablet.problem {
                    Warning(problem)
                }
            } header: {
                Text("Sidecar")
            } footer: {
                Footnote("No iPad app is needed. Sill connects through Sidecar and covers the iPad display with an input-only surface. Sign in to the same Apple Account on both devices. USB requires trusting this Mac on the iPad.")
            }

            Section {
                Picker("Control mode", selection: $tablet.mode) {
                    ForEach(TabletMappingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Toggle("Map the full iPad surface", isOn: Binding(
                    get: { tablet.activeArea.isFull },
                    set: { full in tablet.activeArea = full ? .full : TabletActiveArea(x: 0.1, y: 0.1, width: 0.8, height: 0.8) }
                ))

                if !tablet.activeArea.isFull {
                    areaSlider("Left", keyPath: \.x)
                    areaSlider("Top", keyPath: \.y)
                    areaSlider("Width", keyPath: \.width, range: 0.1...1)
                    areaSlider("Height", keyPath: \.height, range: 0.1...1)
                }
            } header: {
                Text("Mapping")
            } footer: {
                Footnote(tablet.mode == .absolute
                         ? "Tablet mode maps the active iPad area to the Mac’s main display."
                         : "Trackpad mode moves the Mac pointer relative to Pencil or finger movement.")
            }

            Section {
                Toggle("Pencil contact clicks", isOn: $tablet.pencilContactClick)
                Toggle("Finger tap clicks", isOn: $tablet.touchClick)
                    .disabled(!tablet.supportsSidecarTouch)
            } header: {
                Text("Input")
            } footer: {
                Footnote(tablet.supportsSidecarTouch
                         ? "Turn off Pencil contact clicks to move the pointer with Pencil without pressing the Mac mouse button. Finger input requires a compatible iPadOS version."
                         : "Turn off Pencil contact clicks to move the pointer with Pencil without pressing the Mac mouse button. Finger input through Sidecar requires macOS 27 and iPadOS 27.")
            }

            Section {
                Toggle("Connect when Sill opens", isOn: $tablet.connectAtLaunch)
                    .disabled(tablet.selectedDeviceName.isEmpty)
            } header: {
                Text("Automatic connection")
            } footer: {
                Footnote("When enabled, Sill reconnects to the selected iPad on launch. Sidecar must be available and the Mac must have Accessibility permission.")
            }

            if !permissions.accessibility {
                Section {
                    Warning("Accessibility permission is required to move and click the Mac pointer.")
                    Button("Allow Accessibility…") { permissions.requestAccessibility() }
                } header: {
                    Text("Permission")
                }
            }
        }
    }

    private func areaSlider(_ title: String, keyPath: WritableKeyPath<TabletActiveArea, Double>,
                            range: ClosedRange<Double> = 0...1) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: areaBinding(keyPath), in: range)
                    .frame(width: 200)
                Text(areaBinding(keyPath).wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    private func areaBinding(_ keyPath: WritableKeyPath<TabletActiveArea, Double>) -> Binding<Double> {
        Binding(
            get: { tablet.activeArea[keyPath: keyPath] },
            set: { value in
                var area = tablet.activeArea
                area[keyPath: keyPath] = value
                tablet.activeArea = area
            }
        )
    }
}
