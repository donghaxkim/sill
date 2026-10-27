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
                    set: { full in tablet.setActiveArea(full ? .full : TabletActiveArea(x: 0.1, y: 0.1, width: 0.8, height: 0.8)) }
                ))

                LabeledContent("Mapped area") {
                    TabletAreaPreview(area: tablet.activeArea)
                }

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
                         : tablet.fingerInputEnabled
                            ? "Trackpad mode moves the Mac pointer relative to Pencil or finger movement."
                            : "Trackpad mode moves relative to Pencil movement. Turn on Finger input to use your finger too.")
            }

            Section {
                Toggle("Pencil contact clicks", isOn: $tablet.pencilContactClick)
                Toggle("Finger input", isOn: $tablet.fingerInputEnabled)
                    .disabled(!tablet.supportsSidecarTouch)
                Toggle("Finger tap clicks", isOn: $tablet.touchClick)
                    .disabled(!tablet.supportsSidecarTouch || !tablet.fingerInputEnabled)
            } header: {
                Text("Input")
            } footer: {
                Footnote(tablet.supportsSidecarTouch
                         ? "Turn off Pencil contact clicks to move the pointer with Pencil without pressing the Mac mouse button. Turn off Finger input to ignore all finger touches."
                         : "Turn off Pencil contact clicks to move the pointer with Pencil without pressing the Mac mouse button. Finger input requires macOS 27 and iPadOS 27.")
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
                tablet.setActiveArea(area)
            }
        )
    }
}

private struct TabletAreaPreview: View {
    let area: TabletActiveArea

    var body: some View {
        Canvas { context, size in
            let tablet = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
            let tabletPath = Path(roundedRect: tablet, cornerSize: CGSize(width: 14, height: 14))
            context.fill(tabletPath, with: .color(Color(nsColor: NSColor(calibratedWhite: 0.075, alpha: 1))))
            context.stroke(tabletPath, with: .color(.white.opacity(0.18)), lineWidth: 1)

            let mapped = CGRect(x: tablet.minX + tablet.width * area.x,
                                y: tablet.minY + tablet.height * area.y,
                                width: tablet.width * area.width,
                                height: tablet.height * area.height)
            if !area.isFull {
                let inactive = [
                    CGRect(x: tablet.minX, y: tablet.minY, width: tablet.width, height: mapped.minY - tablet.minY),
                    CGRect(x: tablet.minX, y: mapped.maxY, width: tablet.width, height: tablet.maxY - mapped.maxY),
                    CGRect(x: tablet.minX, y: mapped.minY, width: mapped.minX - tablet.minX, height: mapped.height),
                    CGRect(x: mapped.maxX, y: mapped.minY, width: tablet.maxX - mapped.maxX, height: mapped.height),
                ]
                for rect in inactive where !rect.isEmpty {
                    context.fill(Path(rect), with: .color(.black.opacity(0.62)))
                }
            }

            let mappedPath = Path(roundedRect: mapped.insetBy(dx: 1, dy: 1), cornerSize: CGSize(width: 9, height: 9))
            context.fill(mappedPath, with: .color(Color(nsColor: NSColor.controlAccentColor).opacity(0.10)))
            context.stroke(mappedPath, with: .color(Color(nsColor: NSColor.controlAccentColor).opacity(0.88)), lineWidth: 1.5)
        }
        .frame(width: 210, height: 132)
        .accessibilityLabel("iPad mapped area preview")
    }
}
