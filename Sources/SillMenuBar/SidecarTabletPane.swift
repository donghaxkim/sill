import AppKit
import SwiftUI

struct SidecarTabletPane: View {
    @Bindable var tablet: SidecarTabletModel
    @Bindable var permissions: PermissionsModel
    @State private var didJustSaveArea = false
    @State private var saveFeedbackTask: Task<Void, Never>?

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
                        if tablet.isConnected, let deviceName = tablet.connectedDeviceName {
                            Label("Connected to \(deviceName)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Text(tablet.statusText)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    HStack {
                        Button(tablet.isConnected
                               ? (tablet.isUsingExistingSidecarSession ? "Stop mapping" : "Disconnect")
                               : tablet.isConnecting ? "Connecting…" : "Connect") {
                            if tablet.isConnected { tablet.disconnect() }
                            else { tablet.connectSelected() }
                        }
                        .disabled(!tablet.isConnected && !tablet.canConnect)

                        Button("Refresh", systemImage: "arrow.clockwise") { tablet.refreshDevices() }
                            .disabled(tablet.isConnecting)
                    }

                    if tablet.canDisconnectSidecarSession && !tablet.isConnected {
                        Button("Disconnect Sidecar", systemImage: "xmark.circle") {
                            tablet.disconnect()
                        }
                    }

                    if let problem = tablet.problem {
                        VStack(alignment: .leading, spacing: 8) {
                            Warning(problem)
                            HStack(spacing: 12) {
                                if tablet.needsExtendedDisplayRecovery {
                                    Button("Fix display…", systemImage: "display") {
                                        tablet.isDisplayRecoveryPopoverPresented = true
                                    }
                                    .popover(isPresented: $tablet.isDisplayRecoveryPopoverPresented, arrowEdge: .bottom) {
                                        VStack(alignment: .leading, spacing: 12) {
                                            Label("Extended Display required", systemImage: "display")
                                                .font(.headline)
                                            Text(tablet.displayRecoveryMessage)
                                                .fixedSize(horizontal: false, vertical: true)
                                            HStack {
                                                Button("Open Displays Settings") {
                                                    tablet.isDisplayRecoveryPopoverPresented = false
                                                    tablet.openDisplaysSettings()
                                                }
                                                .buttonStyle(.borderedProminent)
                                                Button("Try Again") {
                                                    tablet.isDisplayRecoveryPopoverPresented = false
                                                    tablet.connectSelected()
                                                }
                                            }
                                        }
                                        .padding(16)
                                        .frame(width: 360, alignment: .leading)
                                    }
                                }

                            }
                            .controlSize(.small)
                        }
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Footnote("Uses Sidecar, so no iPad app is needed. Sign in to the same Apple Account on both devices. For USB, trust this Mac on the iPad.")
                }

                Section {
                    if tablet.targetDisplays.count > 1 {
                        Picker("Mac display", selection: $tablet.targetDisplaySelection) {
                            ForEach(tablet.targetDisplays) { display in
                                Text(display.label).tag(Int(display.id))
                            }
                        }
                    } else if let display = tablet.targetDisplays.first {
                        LabeledContent("Mac display", value: display.label)
                    }

                    Picker("Control mode", selection: $tablet.mode) {
                        ForEach(TabletMappingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(tablet.mode == .absolute
                         ? "Tablet maps points inside the active area to matching points on the Mac. Outside input is ignored."
                         : "Trackpad moves the pointer by relative distance inside the active area. Outside input is ignored.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("The Mac pointer stays at the mapped position when you lift the Pencil.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 20) {
                        TabletAreaEditor(area: tablet.activeArea) { area in
                            tablet.setActiveArea(area.bounded())
                        }
                        .frame(width: 320, height: 240)

                        VStack(alignment: .leading, spacing: 12) {
                            Text(tablet.mode == .absolute ? "Mapped area" : "Active area")
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
                                .labelStyle(MappingActionLabelStyle())
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                            }

                            VStack(alignment: .leading, spacing: 7) {
                                Text("Fine-tune")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                areaSlider("Left edge", keyPath: \.x,
                                           range: 0...max(0, 1 - tablet.activeArea.width))
                                areaSlider("Top edge", keyPath: \.y,
                                           range: 0...max(0, 1 - tablet.activeArea.height))
                                areaSlider("Width", keyPath: \.width, range: 0.1...1)
                                areaSlider("Height", keyPath: \.height, range: 0.1...1)

                                HStack(spacing: 8) {
                                    if tablet.hasUnsavedAreaChanges {
                                        Button("Undo", systemImage: "arrow.uturn.backward") {
                                            restoreSavedArea()
                                        }
                                        .labelStyle(MappingActionLabelStyle())
                                        .buttonStyle(.bordered)
                                        .controlSize(.regular)
                                    }
                                    Spacer(minLength: 4)
                                    Button(action: saveArea) {
                                        Text(didJustSaveArea ? "Saved." : "Save")
                                            .contentTransition(.opacity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.regular)
                                    .disabled(!tablet.hasUnsavedAreaChanges)
                                }
                                .padding(.top, 3)
                            }
                            .padding(.top, 5)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    Text("Mapping")
                } footer: {
                    Footnote("Left and Top set the area’s offset from the iPad’s upper-left. Drag to move it or a corner to resize. Width and height range from 10% to 100%. Changes preview live; Save keeps them for next time.")
                }

                Section {
                    Button("Open Menu Bar Settings…", systemImage: "arrow.up.right.square") {
                        tablet.openMenuBarSettings()
                    }
                } header: {
                    Text("Mac menu bar")
                } footer: {
                    Footnote("Choose Always under Automatically hide and show the menu bar. macOS applies this to all displays and shows the bar again when the pointer reaches the top edge.")
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

                if !permissions.pointerEventPosting {
                    Section {
                        Warning("This HitPad build cannot post pointer events. An enabled HitPad entry may belong to an older build.")
                        Footnote("Ad-hoc development builds get a new code identity after each rebuild. If HitPad is already on, remove its old entry and add the currently running build.")
                        Button("Open Accessibility Settings…") {
                            permissions.openPrivacyPane("Privacy_Accessibility")
                        }
                    } header: {
                        Text("Pointer control")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 700)
        .onChange(of: tablet.hasUnsavedAreaChanges) { _, isDirty in
            if isDirty {
                saveFeedbackTask?.cancel()
                withAnimation(.snappy(duration: 0.2)) { didJustSaveArea = false }
            }
        }
        .onDisappear { saveFeedbackTask?.cancel() }
    }

    private func areaSlider(_ title: String, keyPath: WritableKeyPath<TabletActiveArea, Double>,
                            range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 76, alignment: .leading)
            Slider(value: areaBinding(keyPath), in: range)
                .frame(maxWidth: .infinity)
            TextField(title, value: areaBinding(keyPath),
                      format: .percent.precision(.fractionLength(1)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 58)
                .accessibilityLabel(title)
        }
        .font(.callout)
    }

    private func saveArea() {
        tablet.saveActiveArea()
        saveFeedbackTask?.cancel()
        withAnimation(.snappy(duration: 0.2)) { didJustSaveArea = true }
        saveFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.2)) { didJustSaveArea = false }
        }
    }

    private func restoreSavedArea() {
        saveFeedbackTask?.cancel()
        withAnimation(.snappy(duration: 0.2)) {
            tablet.restoreSavedActiveArea()
            didJustSaveArea = false
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
        value.formatted(.percent.precision(.fractionLength(1)))
    }
}

private struct MappingActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .frame(width: 14)
            configuration.title
        }
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
