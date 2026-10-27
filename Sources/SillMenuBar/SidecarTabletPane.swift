import AppKit
import SwiftUI

struct SidecarTabletPane: View {
    @Bindable var tablet: SidecarTabletModel
    @Bindable var permissions: PermissionsModel
    @State private var fineTuneArea = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Map your iPad to your Mac display.")
                    .font(.title3.weight(.semibold))
                Text("Choose an active area and how Pencil or touch controls the pointer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 6)

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
                        Button(tablet.isConnected ? "Disconnect" : tablet.isConnecting ? "Connecting…" : "Connect") {
                            if tablet.isConnected { tablet.disconnect() }
                            else { tablet.connectSelected() }
                        }
                        .disabled(!tablet.isConnected && !tablet.canConnect)

                        Button("Refresh", systemImage: "arrow.clockwise") { tablet.refreshDevices() }
                            .disabled(tablet.isConnecting)
                    }

                    if let problem = tablet.problem {
                        Warning(problem)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Footnote("Uses Sidecar, so no iPad app is needed. Sign in to the same Apple Account on both devices. For USB, trust this Mac on the iPad.")
                }

                Section {
                    Picker("Control mode", selection: $tablet.mode) {
                        ForEach(TabletMappingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(alignment: .top, spacing: 20) {
                        TabletAreaEditor(area: tablet.activeArea) { area in
                            tablet.setActiveArea(area.bounded())
                        }
                        .frame(width: 320, height: 240)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Mapped area")
                                .font(.headline)

                            LabeledContent("Position") {
                                Text("X \(percent(tablet.activeArea.x))  Y \(percent(tablet.activeArea.y))")
                                    .monospacedDigit()
                            }
                            LabeledContent("Size") {
                                Text("\(percent(tablet.activeArea.width)) × \(percent(tablet.activeArea.height))")
                                    .monospacedDigit()
                            }

                            if !tablet.activeArea.isFull {
                                Button("Use full surface", systemImage: "arrow.up.left.and.arrow.down.right") {
                                    tablet.setActiveArea(.full)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    DisclosureGroup("Fine-tune area", isExpanded: $fineTuneArea) {
                        areaSlider("X position", keyPath: \.x, range: 0...max(0, 1 - tablet.activeArea.width))
                        areaSlider("Y position", keyPath: \.y, range: 0...max(0, 1 - tablet.activeArea.height))
                        areaSlider("Width", keyPath: \.width, range: 0.1...1)
                        areaSlider("Height", keyPath: \.height, range: 0.1...1)
                    }
                } header: {
                    Text("Mapping")
                } footer: {
                    Footnote(tablet.mode == .absolute
                             ? "Tablet maps the selected iPad area to the Mac display. Drag the area to move it or a corner to resize it."
                             : "Trackpad moves the Mac pointer relative to Pencil or finger movement. The selected area limits where input is read.")
                }

                Section {
                    Toggle("Pencil contact clicks", isOn: $tablet.pencilContactClick)

                    Toggle("Finger input", isOn: $tablet.fingerInputEnabled)
                        .disabled(!tablet.supportsSidecarTouch)

                    if tablet.fingerInputEnabled && tablet.supportsSidecarTouch {
                        Toggle("Finger tap clicks", isOn: $tablet.touchClick)
                    }
                } header: {
                    Text("Input")
                } footer: {
                    Footnote(tablet.supportsSidecarTouch
                             ? "Turn off Pencil contact clicks for hover-only positioning. Finger input reads touches from the iPad; tap clicks are optional."
                             : "Pencil contact clicks can be turned off for hover-only positioning. Finger input requires macOS 27 and iPadOS 27.")
                }

                Section {
                    Toggle("Connect when this app opens", isOn: $tablet.connectAtLaunch)
                        .disabled(tablet.selectedDeviceName.isEmpty)
                } header: {
                    Text("Automatic connection")
                } footer: {
                    Footnote("Reconnect to the selected iPad whenever this app starts.")
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
            .formStyle(.grouped)
        }
        .frame(width: 700)
    }

    private func areaSlider(_ title: String, keyPath: WritableKeyPath<TabletActiveArea, Double>,
                            range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: areaBinding(keyPath), in: range)
                    .frame(width: 220)
                Text(percent(tablet.activeArea[keyPath: keyPath]))
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
                tablet.setActiveArea(area.bounded())
            }
        )
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct TabletAreaEditor: View {
    private enum DragTarget: String {
        case move, topLeading, topTrailing, bottomLeading, bottomTrailing
    }

    let area: TabletActiveArea
    let onChange: (TabletActiveArea) -> Void
    @State private var dragOrigin: TabletActiveArea?

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 1, dy: 1)
            let mapped = mappedRect(in: bounds)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        Canvas { context, size in
                            var grid = Path()
                            for step in 1...3 {
                                let x = size.width * CGFloat(step) / 4
                                let y = size.height * CGFloat(step) / 4
                                grid.move(to: CGPoint(x: x, y: 8))
                                grid.addLine(to: CGPoint(x: x, y: size.height - 8))
                                grid.move(to: CGPoint(x: 8, y: y))
                                grid.addLine(to: CGPoint(x: size.width - 8, y: y))
                            }
                            context.stroke(grid, with: .color(.primary.opacity(0.08)), lineWidth: 0.7)

                            var inactive = Path(roundedRect: bounds, cornerSize: CGSize(width: 14, height: 14))
                            inactive.addPath(Path(roundedRect: mapped, cornerSize: CGSize(width: 8, height: 8)))
                            context.fill(inactive, with: .color(.black.opacity(0.22)), style: FillStyle(eoFill: true))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    }

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                    .frame(width: mapped.width, height: mapped.height)
                    .position(x: mapped.midX, y: mapped.midY)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .gesture(dragGesture(.move, in: bounds))
                    .help("Drag to move the mapped area")

                ForEach(Handle.allCases) { handle in
                    Circle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .position(handle.position(in: mapped))
                        .gesture(dragGesture(handle.target, in: bounds))
                        .help("Drag to resize the mapped area")
                }

                Text("iPad surface")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
                    .padding(.top, 5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("iPad mapped area editor")
        .help("Drag the highlighted area to move it. Drag a corner handle to resize it.")
    }

    private func mappedRect(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + bounds.width * area.x,
               y: bounds.minY + bounds.height * area.y,
               width: bounds.width * area.width,
               height: bounds.height * area.height)
    }

    private func dragGesture(_ target: DragTarget, in bounds: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let origin = dragOrigin ?? area
                dragOrigin = origin
                let dx = Double(value.translation.width / bounds.width)
                let dy = Double(value.translation.height / bounds.height)
                var next = origin

                switch target {
                case .move:
                    next.x += dx
                    next.y += dy
                case .topLeading:
                    next.x += dx
                    next.y += dy
                    next.width -= dx
                    next.height -= dy
                case .topTrailing:
                    next.y += dy
                    next.width += dx
                    next.height -= dy
                case .bottomLeading:
                    next.x += dx
                    next.width -= dx
                    next.height += dy
                case .bottomTrailing:
                    next.width += dx
                    next.height += dy
                }

                onChange(next.bounded())
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private enum Handle: String, CaseIterable, Identifiable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var id: String { rawValue }
        var target: DragTarget {
            switch self {
            case .topLeading: .topLeading
            case .topTrailing: .topTrailing
            case .bottomLeading: .bottomLeading
            case .bottomTrailing: .bottomTrailing
            }
        }

        func position(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeading: CGPoint(x: rect.minX + 6, y: rect.minY + 6)
            case .topTrailing: CGPoint(x: rect.maxX - 6, y: rect.minY + 6)
            case .bottomLeading: CGPoint(x: rect.minX + 6, y: rect.maxY - 6)
            case .bottomTrailing: CGPoint(x: rect.maxX - 6, y: rect.maxY - 6)
            }
        }
    }
}
