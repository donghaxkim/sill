import AppKit
import CoreGraphics
import Darwin
import Observation

enum TabletMappingMode: String, CaseIterable, Identifiable {
    case absolute
    case relative

    var id: String { rawValue }
    var title: String { self == .absolute ? "Tablet" : "Trackpad" }
}

struct TabletActiveArea: Codable, Equatable {
    var x = 0.0
    var y = 0.0
    var width = 1.0
    var height = 1.0

    static let full = TabletActiveArea()
    var isFull: Bool { self == .full }

    func normalized(_ point: CGPoint) -> CGPoint? {
        guard width > 0, height > 0 else { return nil }
        let px = (point.x - x) / width
        let py = (point.y - y) / height
        guard (0...1).contains(px), (0...1).contains(py) else { return nil }
        return CGPoint(x: px, y: py)
    }

    func bounded() -> TabletActiveArea {
        var result = self
        result.width = min(max(width, 0.1), 1)
        result.height = min(max(height, 0.1), 1)
        result.x = min(max(x, 0), 1 - result.width)
        result.y = min(max(y, 0), 1 - result.height)
        return result
    }

    func roundedToTenthPercent() -> TabletActiveArea {
        var result = bounded()
        result.x = (result.x * 1_000).rounded() / 1_000
        result.y = (result.y * 1_000).rounded() / 1_000
        result.width = (result.width * 1_000).rounded() / 1_000
        result.height = (result.height * 1_000).rounded() / 1_000
        return result.bounded()
    }
}

struct SidecarDevice: Identifiable, Equatable {
    let name: String
    var id: String { name }
}

struct TabletTargetDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool

    var label: String { isBuiltIn ? "\(name) (Built-in)" : name }
}

/// The Sidecar connection entry points are private on macOS. Keep their use isolated here so the
/// input surface and the rest of HitPad do not depend on the private class or its selectors.
@MainActor
private final class SidecarBridge {
    private let frameworkPath = "/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore"

    func devices() throws -> [SidecarDevice] {
        try sidecarDevices().map { device in
            let name = (device.perform(NSSelectorFromString("name"))?.takeUnretainedValue() as? String) ?? ""
            return SidecarDevice(name: name)
        }.filter { !$0.name.isEmpty }
    }

    func connect(name: String) async throws {
        try await performConnection(selector: "connectToDevice:completion:", name: name)
    }

    func disconnect(name: String) async throws {
        try await performConnection(selector: "disconnectFromDevice:completion:", name: name)
    }

    /// macOS can expose a mirrored Sidecar display in CoreGraphics before AppKit lists it as an
    /// NSScreen. Reuse it only when its Sidecar vendor marker is unique, so another Apple display
    /// cannot be mistaken for the selected iPad.
    func sidecarDisplayID() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        let candidates = ids.prefix(Int(count)).filter {
            CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) == 0x6161_706C
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    func extendDisplay(_ id: CGDirectDisplayID) throws {
        guard CGDisplayIsInMirrorSet(id) != 0 else { return }
        guard CGDisplayIsAlwaysInMirrorSet(id) == 0 else {
            throw SidecarError("macOS is keeping the iPad in mirror mode.", requiresExtendedDisplay: true)
        }
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
            throw SidecarError("macOS couldn’t prepare the iPad display for tablet input.", requiresExtendedDisplay: true)
        }
        let configureResult = CGConfigureDisplayMirrorOfDisplay(configuration, id, kCGNullDirectDisplay)
        guard configureResult == .success else {
            CGCancelDisplayConfiguration(configuration)
            throw SidecarError("macOS couldn’t switch the iPad to Extended Display.", requiresExtendedDisplay: true)
        }
        guard CGCompleteDisplayConfiguration(configuration, .forSession) == .success else {
            throw SidecarError("macOS couldn’t apply the Extended Display setting.", requiresExtendedDisplay: true)
        }
    }

    private func sidecarDevices() throws -> [NSObject] {
        guard dlopen(frameworkPath, RTLD_LAZY) != nil else {
            throw SidecarError("Sidecar isn’t available on this Mac.")
        }
        guard let type = NSClassFromString("SidecarDisplayManager") as? NSObject.Type,
              let manager = type.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject else {
            throw SidecarError("macOS changed its Sidecar connection interface.")
        }
        guard manager.responds(to: NSSelectorFromString("devices")),
              let devices = manager.perform(NSSelectorFromString("devices"))?.takeUnretainedValue() as? [NSObject] else {
            throw SidecarError("macOS didn’t return any available Sidecar devices.")
        }
        return devices
    }

    private func performConnection(selector name: String, name deviceName: String) async throws {
        let devices = try sidecarDevices()
        guard let device = devices.first(where: {
            ($0.perform(NSSelectorFromString("name"))?.takeUnretainedValue() as? String) == deviceName
        }) else {
            throw SidecarError("\(deviceName) isn’t currently available to Sidecar.")
        }

        let type = NSClassFromString("SidecarDisplayManager") as? NSObject.Type
        guard let manager = type?.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject else {
            throw SidecarError("macOS changed its Sidecar connection interface.")
        }
        let selector = NSSelectorFromString(name)
        guard manager.responds(to: selector) else {
            throw SidecarError("macOS no longer supports Sidecar connection through this interface.")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion: @convention(block) (NSError?) -> Void = { error in
                DispatchQueue.main.async {
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            _ = manager.perform(selector, with: device, with: completion)
        }
    }
}

private struct SidecarError: LocalizedError {
    let message: String
    let requiresExtendedDisplay: Bool

    init(_ message: String, requiresExtendedDisplay: Bool = false) {
        self.message = message
        self.requiresExtendedDisplay = requiresExtendedDisplay
    }

    var errorDescription: String? { message }
}

@MainActor
@Observable
final class SidecarTabletModel {
    private enum Key {
        static let selectedDevice = "HitPad.tablet.sidecarDevice"
        static let mode = "HitPad.tablet.mappingMode"
        static let pencilClick = "HitPad.tablet.pencilClick"
        static let fingerInput = "HitPad.tablet.fingerInput"
        static let touchClick = "HitPad.tablet.touchClick"
        static let activeArea = "HitPad.tablet.activeArea"
        static let connectAtLaunch = "HitPad.tablet.connectAtLaunch"
        static let targetDisplay = "HitPad.tablet.targetDisplay"
    }

    private let defaults: UserDefaults
    private let bridge = SidecarBridge()
    private var surfaceWindow: TabletSurfaceWindowController?
    private var screenObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var hiddenCursorDisplayID: CGDirectDisplayID?
    private var ownsSidecarConnection = false
    private var sidecarSessionDeviceName: String?
    private(set) var isDisconnectingSidecar = false
    @ObservationIgnored var requestPointerEventAccess: (() -> Bool)?
    @ObservationIgnored var presentTabletSettingsForDisplayRecovery: (() -> Void)?

    private(set) var devices: [SidecarDevice] = []
    private(set) var connectedDeviceName: String?
    private(set) var isConnecting = false
    private(set) var problem: String?
    private(set) var needsExtendedDisplayRecovery = false
    var isDisplayRecoveryPopoverPresented = false
    private(set) var targetDisplays: [TabletTargetDisplay] = []
    private(set) var selectedTargetDisplayID: CGDirectDisplayID?

    var selectedDeviceName: String {
        didSet { defaults.set(selectedDeviceName, forKey: Key.selectedDevice) }
    }
    var mode: TabletMappingMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Key.mode)
            updateSurface()
        }
    }
    var pencilContactClick: Bool {
        didSet {
            defaults.set(pencilContactClick, forKey: Key.pencilClick)
            updateSurface()
        }
    }
    var fingerInputEnabled: Bool {
        didSet {
            defaults.set(fingerInputEnabled, forKey: Key.fingerInput)
            updateSurface()
        }
    }
    var touchClick: Bool {
        didSet {
            defaults.set(touchClick, forKey: Key.touchClick)
            updateSurface()
        }
    }
    private(set) var activeArea: TabletActiveArea { didSet { updateSurface() } }
    private(set) var savedActiveArea: TabletActiveArea
    var connectAtLaunch: Bool {
        didSet { defaults.set(connectAtLaunch, forKey: Key.connectAtLaunch) }
    }
    var targetDisplayID: CGDirectDisplayID {
        selectedTargetDisplayID ?? targetDisplays.first(where: \.isBuiltIn)?.id ?? CGMainDisplayID()
    }
    var targetDisplaySelection: Int {
        get { Int(targetDisplayID) }
        set {
            let id = CGDirectDisplayID(newValue)
            guard targetDisplays.contains(where: { $0.id == id }), selectedTargetDisplayID != id else { return }
            selectedTargetDisplayID = id
            defaults.set(newValue, forKey: Key.targetDisplay)
        }
    }

    var isConnected: Bool { connectedDeviceName != nil }
    var isUsingExistingSidecarSession: Bool { isConnected && !ownsSidecarConnection }
    var canDisconnectSidecarSession: Bool {
        ownsSidecarConnection && sidecarSessionDeviceName != nil && !isDisconnectingSidecar
    }
    var hasUnsavedAreaChanges: Bool { activeArea != savedActiveArea }
    var supportsSidecarTouch: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }
    var canConnect: Bool {
        !isConnected && !isConnecting && !isDisconnectingSidecar && !selectedDeviceName.isEmpty
    }
    var statusText: String {
        if isConnecting { return "Connecting to Sidecar…" }
        if isDisconnectingSidecar { return "Disconnecting from Sidecar…" }
        if let connectedDeviceName { return "Connected to \(connectedDeviceName)" }
        if let problem { return problem }
        return devices.isEmpty ? "No Sidecar iPads found" : "Ready to connect"
    }
    var displayRecoveryMessage: String {
        let error = problem ?? "The iPad isn’t available as an extended display."
        return "\(error)\n\nHitPad needs the iPad set to Extend Display. In System Settings > Displays, choose Extend Display for the iPad, then try again."
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedDeviceName = defaults.string(forKey: Key.selectedDevice) ?? ""
        mode = TabletMappingMode(rawValue: defaults.string(forKey: Key.mode) ?? "absolute") ?? .absolute
        pencilContactClick = defaults.object(forKey: Key.pencilClick) as? Bool ?? true
        fingerInputEnabled = defaults.bool(forKey: Key.fingerInput)
        touchClick = defaults.object(forKey: Key.touchClick) as? Bool ?? true
        let initialArea: TabletActiveArea
        if let data = defaults.data(forKey: Key.activeArea), let area = try? JSONDecoder().decode(TabletActiveArea.self, from: data) {
            initialArea = area.roundedToTenthPercent()
        } else {
            initialArea = .full
        }
        activeArea = initialArea
        savedActiveArea = initialArea
        connectAtLaunch = defaults.bool(forKey: Key.connectAtLaunch)
        selectedTargetDisplayID = (defaults.object(forKey: Key.targetDisplay) as? NSNumber)?.uint32Value
    }

    func start() {
        refreshDevices()
        refreshTargetDisplays()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sidecarDisplaysChanged() }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreSidecarCursor() }
        }
        guard connectAtLaunch else { return }
        if selectedDeviceName.isEmpty, devices.count == 1 { selectedDeviceName = devices[0].name }
        connectSelected()
    }

    func setActiveArea(_ area: TabletActiveArea) {
        let area = area.roundedToTenthPercent()
        guard area != activeArea else { return }
        activeArea = area
    }

    func saveActiveArea() {
        guard hasUnsavedAreaChanges else { return }
        savedActiveArea = activeArea
        if let data = try? JSONEncoder().encode(savedActiveArea) { defaults.set(data, forKey: Key.activeArea) }
    }

    func restoreSavedActiveArea() {
        setActiveArea(savedActiveArea)
    }

    func refreshDevices() {
        do {
            devices = try bridge.devices()
            if selectedDeviceName.isEmpty, devices.count == 1 { selectedDeviceName = devices[0].name }
            if !selectedDeviceName.isEmpty, !devices.contains(where: { $0.name == selectedDeviceName }) {
                problem = "\(selectedDeviceName) isn’t currently available."
                clearDisplayRecovery()
            } else if !isConnected && !needsExtendedDisplayRecovery {
                problem = nil
                clearDisplayRecovery()
            }
        } catch {
            devices = []
            problem = error.localizedDescription
            clearDisplayRecovery()
        }
    }

    func connectSelected() {
        guard canConnect else { return }
        Task { await connect(name: selectedDeviceName) }
    }

    func disconnect() {
        guard let name = connectedDeviceName ?? sidecarSessionDeviceName else { return }
        let shouldDisconnectSidecar = ownsSidecarConnection
        surfaceWindow?.close()
        surfaceWindow = nil
        restoreSidecarCursor()
        connectedDeviceName = nil
        guard shouldDisconnectSidecar else {
            sidecarSessionDeviceName = nil
            clearDisplayRecovery()
            return
        }
        guard !isDisconnectingSidecar else { return }
        isDisconnectingSidecar = true
        clearDisplayRecovery()
        Task {
            defer { isDisconnectingSidecar = false }
            do {
                try await bridge.disconnect(name: name)
                ownsSidecarConnection = false
                sidecarSessionDeviceName = nil
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func connect(name: String) async {
        guard !isConnected, !isDisconnectingSidecar else { return }
        problem = nil
        clearDisplayRecovery()
        if !CGPreflightPostEventAccess() {
            let requestReportedAccess = requestPointerEventAccess?() ?? CGRequestPostEventAccess()
            guard CGPreflightPostEventAccess() else {
                problem = requestReportedAccess
                    ? "macOS reported access, but this HitPad build still cannot post pointer events. Replace its Accessibility entry with the currently running build, then click Connect again."
                    : "This HitPad build cannot post pointer events. If HitPad is already enabled in Accessibility, its entry may belong to an older build."
                return
            }
        }
        isConnecting = true
        problem = nil
        defer { isConnecting = false }
        let existingDisplayID = bridge.sidecarDisplayID()
        var startedSidecarConnection = false
        if let sessionName = sidecarSessionDeviceName, sessionName != name {
            problem = "Sidecar is already open for \(sessionName). Disconnect it before connecting to \(name)."
            return
        }
        if existingDisplayID != nil, sidecarSessionDeviceName == nil {
            guard devices.count == 1, devices[0].name == name else {
                problem = "An existing Sidecar display is active, but HitPad can’t identify its iPad. Disconnect it in Displays, then select an iPad and connect again."
                return
            }
            ownsSidecarConnection = false
            sidecarSessionDeviceName = name
        }
        do {
            if existingDisplayID == nil {
                try await bridge.connect(name: name)
                startedSidecarConnection = true
                ownsSidecarConnection = true
                sidecarSessionDeviceName = name
            }
            let displayID: CGDirectDisplayID?
            if let existingDisplayID {
                displayID = existingDisplayID
            } else {
                displayID = await waitForSidecarDisplayID()
            }
            guard let id = displayID else {
                if startedSidecarConnection, !(await releaseOwnedSidecarSession(named: name)) { return }
                problem = "Sidecar connected, but the iPad display didn’t become available."
                return
            }
            try bridge.extendDisplay(id)
            guard CGDisplayIsInMirrorSet(id) == 0 else {
                showDisplayRecovery("macOS kept the iPad in Mirror mode.")
                return
            }
            guard let screen = await waitForScreen(id: id) else {
                let message = "The iPad display didn’t become available in Extended Display mode."
                if CGDisplayIsInMirrorSet(id) != 0 {
                    showDisplayRecovery(message)
                } else {
                    if startedSidecarConnection, !(await releaseOwnedSidecarSession(named: name)) { return }
                    problem = message
                }
                return
            }
            guard CGDisplayIsInMirrorSet(id) == 0 else {
                showDisplayRecovery("macOS kept the iPad in Mirror mode.")
                return
            }
            surfaceWindow?.close()
            surfaceWindow = TabletSurfaceWindowController(screen: screen, model: self)
            sidecarSessionDeviceName = name
            connectedDeviceName = name
            selectedDeviceName = name
            problem = nil
            clearDisplayRecovery()
            refreshTargetDisplays()
            hideCursorOnSidecarDisplay(id)
        } catch {
            let requiresDisplayRecovery = (error as? SidecarError)?.requiresExtendedDisplay == true
                || bridge.sidecarDisplayID().map({ CGDisplayIsInMirrorSet($0) != 0 }) == true
            if requiresDisplayRecovery {
                showDisplayRecovery(error.localizedDescription)
            } else {
                if startedSidecarConnection, !(await releaseOwnedSidecarSession(named: name)) { return }
                problem = error.localizedDescription
            }
        }
    }

    private func releaseOwnedSidecarSession(named name: String) async -> Bool {
        guard ownsSidecarConnection, sidecarSessionDeviceName == name else { return true }
        do {
            try await bridge.disconnect(name: name)
            ownsSidecarConnection = false
            sidecarSessionDeviceName = nil
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    func openDisplaysSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func openMenuBarSettings() {
        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let pane = majorVersion >= 26
            ? "com.apple.ControlCenter-Settings.extension"
            : "com.apple.controlcenter"
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        if !NSWorkspace.shared.open(url),
           let fallback = URL(string: "x-apple.systempreferences:com.apple.controlcenter") {
            NSWorkspace.shared.open(fallback)
        }
    }

    private func showDisplayRecovery(_ message: String) {
        problem = message
        needsExtendedDisplayRecovery = true
        isDisplayRecoveryPopoverPresented = true
        presentTabletSettingsForDisplayRecovery?()
    }

    private func clearDisplayRecovery() {
        needsExtendedDisplayRecovery = false
        isDisplayRecoveryPopoverPresented = false
    }

    private func refreshTargetDisplays() {
        let sidecarID = bridge.sidecarDisplayID()
        let displays = NSScreen.screens.compactMap { screen -> TabletTargetDisplay? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = CGDirectDisplayID(number.uint32Value)
            guard id != sidecarID else { return nil }
            return TabletTargetDisplay(id: id, name: screen.localizedName, isBuiltIn: CGDisplayIsBuiltin(id) != 0)
        }.sorted { lhs, rhs in
            if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
            let lhsIsMain = lhs.id == CGMainDisplayID()
            let rhsIsMain = rhs.id == CGMainDisplayID()
            if lhsIsMain != rhsIsMain { return lhsIsMain }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        targetDisplays = displays

        if let selectedTargetDisplayID, displays.contains(where: { $0.id == selectedTargetDisplayID }) { return }
        let savedID = (defaults.object(forKey: Key.targetDisplay) as? NSNumber)?.uint32Value
        let preferredID = savedID.flatMap { id in displays.contains(where: { $0.id == id }) ? id : nil }
            ?? displays.first(where: \.isBuiltIn)?.id
            ?? displays.first(where: { $0.id == CGMainDisplayID() })?.id
            ?? displays.first?.id
        selectedTargetDisplayID = preferredID
        if let preferredID { defaults.set(Int(preferredID), forKey: Key.targetDisplay) }
        else { defaults.removeObject(forKey: Key.targetDisplay) }
    }

    private func hideCursorOnSidecarDisplay(_ id: CGDirectDisplayID) {
        guard hiddenCursorDisplayID != id else { return }
        restoreSidecarCursor()
        guard hiddenCursorDisplayID == nil else { return }
        guard CGDisplayHideCursor(id) == .success else {
            problem = "macOS couldn’t hide the cursor on the iPad display."
            return
        }
        hiddenCursorDisplayID = id
    }

    private func restoreSidecarCursor() {
        guard let id = hiddenCursorDisplayID else { return }
        guard CGDisplayShowCursor(id) == .success else {
            problem = "macOS couldn’t restore the cursor on the iPad display."
            return
        }
        hiddenCursorDisplayID = nil
    }

    private func waitForSidecarDisplayID() async -> CGDirectDisplayID? {
        for _ in 0..<50 {
            if let id = bridge.sidecarDisplayID() { return id }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private func waitForScreen(id: CGDirectDisplayID) async -> NSScreen? {
        for _ in 0..<50 {
            if let screen = screen(for: id) { return screen }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    private func sidecarDisplaysChanged() {
        refreshTargetDisplays()
        guard let connectedDeviceName else {
            restoreSidecarCursor()
            if needsExtendedDisplayRecovery,
               let id = bridge.sidecarDisplayID(),
               CGDisplayIsInMirrorSet(id) == 0,
               screen(for: id) != nil {
                problem = nil
                clearDisplayRecovery()
            }
            return
        }
        guard let id = bridge.sidecarDisplayID() else {
            restoreSidecarCursor()
            surfaceWindow?.close()
            surfaceWindow = nil
            self.connectedDeviceName = nil
            ownsSidecarConnection = false
            sidecarSessionDeviceName = nil
            problem = "The Sidecar display disconnected."
            return
        }
        if CGDisplayIsInMirrorSet(id) != 0 {
            restoreSidecarCursor()
            surfaceWindow?.close()
            surfaceWindow = nil
            self.connectedDeviceName = nil
            showDisplayRecovery("The iPad switched to Mirror mode, so tablet mapping stopped.")
            return
        }
        guard let screen = screen(for: id) else {
            restoreSidecarCursor()
            surfaceWindow?.close()
            surfaceWindow = nil
            self.connectedDeviceName = nil
            problem = "The iPad display is unavailable, so tablet mapping stopped."
            return
        }
        surfaceWindow?.move(to: screen)
        self.connectedDeviceName = connectedDeviceName
        hideCursorOnSidecarDisplay(id)
    }

    private func updateSurface() {
        surfaceWindow?.apply(mode: mode, activeArea: activeArea, pencilClick: pencilContactClick,
                             fingerInputEnabled: fingerInputEnabled && supportsSidecarTouch, touchClick: touchClick)
    }
}

@MainActor
private final class TabletSurfaceWindowController: NSWindowController {
    private let surface: SidecarTabletInputView

    init(screen: NSScreen, model: SidecarTabletModel) {
        let window = TabletSurfaceWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        surface = SidecarTabletInputView(frame: NSRect(origin: .zero, size: screen.frame.size), model: model)
        window.contentView = surface
        window.backgroundColor = NSColor(calibratedWhite: 0.035, alpha: 1)
        window.isOpaque = true
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setFrame(screen.frame, display: true)
        super.init(window: window)
        window.makeKeyAndOrderFront(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func apply(mode: TabletMappingMode, activeArea: TabletActiveArea, pencilClick: Bool,
               fingerInputEnabled: Bool, touchClick: Bool) {
        surface.apply(mode: mode, activeArea: activeArea, pencilClick: pencilClick,
                      fingerInputEnabled: fingerInputEnabled, touchClick: touchClick)
    }

    func move(to screen: NSScreen) {
        window?.setFrame(screen.frame, display: true)
        surface.frame = NSRect(origin: .zero, size: screen.frame.size)
    }
}

@MainActor
private final class TabletSurfaceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class SidecarTabletInputView: NSView, NSGestureRecognizerDelegate {
    private weak var model: SidecarTabletModel?
    private let router = SidecarPointerRouter()
    private var mode: TabletMappingMode = .absolute
    private var activeArea = TabletActiveArea.full
    private var pencilClick = true
    private var fingerInputEnabled = false
    private var touchClick = true
    private var lastTouchPoint: CGPoint?
    private var lastPointerPoint: CGPoint?
    private var pencilButtonIsDown = false
    private var rightButtonIsDown = false
    private var tracking: NSTrackingArea?

    init(frame: NSRect, model: SidecarTabletModel) {
        self.model = model
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.035, alpha: 1).cgColor
        let pan = NSPanGestureRecognizer(target: self, action: #selector(directTouchPan(_:)))
        pan.delegate = self
        pan.buttonMask = 0
        addGestureRecognizer(pan)
        let tap = NSClickGestureRecognizer(target: self, action: #selector(directTouchTap(_:)))
        tap.delegate = self
        tap.buttonMask = 0
        addGestureRecognizer(tap)
        apply(mode: model.mode, activeArea: model.activeArea, pencilClick: model.pencilContactClick,
              fingerInputEnabled: model.fingerInputEnabled && model.supportsSidecarTouch, touchClick: model.touchClick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.acceptsMouseMovedEvents = true }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    func apply(mode: TabletMappingMode, activeArea: TabletActiveArea, pencilClick: Bool,
               fingerInputEnabled: Bool, touchClick: Bool) {
        let nextArea = activeArea.bounded()
        if self.mode != mode || self.activeArea != nextArea {
            lastPointerPoint = nil
            lastTouchPoint = nil
        }
        self.mode = mode
        self.activeArea = nextArea
        self.pencilClick = pencilClick
        self.fingerInputEnabled = fingerInputEnabled
        self.touchClick = touchClick
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let tabletRect = bounds.insetBy(dx: 16, dy: 16)
        let tabletPath = NSBezierPath(roundedRect: tabletRect, xRadius: 18, yRadius: 18)
        NSColor(calibratedWhite: 0.075, alpha: 1).setFill()
        tabletPath.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        tabletPath.lineWidth = 1
        tabletPath.stroke()

        let activeRect = NSRect(x: tabletRect.minX + tabletRect.width * activeArea.x,
                                y: tabletRect.minY + tabletRect.height * (1 - activeArea.y - activeArea.height),
                                width: tabletRect.width * activeArea.width,
                                height: tabletRect.height * activeArea.height)
        if !activeArea.isFull {
            let inactivePath = NSBezierPath(rect: tabletRect)
            inactivePath.append(NSBezierPath(roundedRect: activeRect, xRadius: 10, yRadius: 10))
            inactivePath.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.62).setFill()
            inactivePath.fill()
        }

        let activePath = NSBezierPath(roundedRect: activeRect.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        activePath.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.88).setStroke()
        activePath.lineWidth = 1.5
        activePath.stroke()
    }

    override func mouseMoved(with event: NSEvent) { route(event.locationInWindow) }
    override func mouseDown(with event: NSEvent) {
        guard route(event.locationInWindow) else { return }
        guard pencilClick else { return }
        router.click(down: true)
        pencilButtonIsDown = true
    }
    override func mouseUp(with event: NSEvent) {
        guard pencilButtonIsDown else { return }
        router.click(down: false)
        pencilButtonIsDown = false
    }
    override func mouseDragged(with event: NSEvent) { route(event.locationInWindow) }
    override func rightMouseDown(with event: NSEvent) {
        guard route(event.locationInWindow) else { return }
        router.rightClick(down: true)
        rightButtonIsDown = true
    }
    override func rightMouseUp(with event: NSEvent) {
        guard rightButtonIsDown else { return }
        router.rightClick(down: false)
        rightButtonIsDown = false
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        fingerInputEnabled && touch.type == .direct
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        false
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        true
    }

    @objc private func directTouchPan(_ recognizer: NSPanGestureRecognizer) {
        guard fingerInputEnabled else {
            lastTouchPoint = nil
            return
        }
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            lastPointerPoint = nil
            if isInsideActiveArea(point) {
                lastTouchPoint = point
                if mode == .absolute { routeLocal(point) }
            } else {
                lastTouchPoint = nil
            }
        case .changed:
            guard isInsideActiveArea(point) else {
                lastTouchPoint = nil
                return
            }
            if mode == .relative, let lastTouchPoint {
                router.moveRelative(dx: point.x - lastTouchPoint.x,
                                    dy: lastTouchPoint.y - point.y,
                                    surfaceSize: trackpadSurfaceSize,
                                    displayID: targetDisplayID)
            } else {
                if mode == .absolute { routeLocal(point) }
            }
            lastTouchPoint = point
        case .ended, .cancelled, .failed:
            lastTouchPoint = nil
            lastPointerPoint = nil
        default: break
        }
    }

    @objc private func directTouchTap(_ recognizer: NSClickGestureRecognizer) {
        guard fingerInputEnabled, recognizer.state == .ended else { return }
        let point = recognizer.location(in: self)
        guard isInsideActiveArea(point) else { return }
        if mode == .absolute {
            routeLocal(point)
        } else {
            // A trackpad tap clicks at the current pointer location; it should not jump to
            // the tap position or reuse a stale Pencil position as the next movement origin.
            lastPointerPoint = nil
        }
        guard touchClick else { return }
        router.click(down: true)
        router.click(down: false)
    }

    @discardableResult
    private func route(_ windowPoint: NSPoint) -> Bool {
        routeLocal(convert(windowPoint, from: nil))
    }

    @discardableResult
    private func routeLocal(_ local: NSPoint) -> Bool {
        let u = local.x / max(bounds.width, 1)
        let v = 1 - local.y / max(bounds.height, 1)
        guard let normalized = activeArea.normalized(CGPoint(x: u, y: v)) else {
            lastPointerPoint = nil
            return false
        }
        if mode == .absolute {
            router.moveAbsolute(normalized: normalized, displayID: targetDisplayID)
            lastPointerPoint = nil
        } else {
            if let lastPointerPoint {
                router.moveRelative(dx: local.x - lastPointerPoint.x,
                                    dy: lastPointerPoint.y - local.y,
                                    surfaceSize: trackpadSurfaceSize,
                                    displayID: targetDisplayID)
            }
            lastPointerPoint = local
        }
        return true
    }

    private func isInsideActiveArea(_ local: CGPoint) -> Bool {
        let u = local.x / max(bounds.width, 1)
        let v = 1 - local.y / max(bounds.height, 1)
        return activeArea.normalized(CGPoint(x: u, y: v)) != nil
    }

    private var trackpadSurfaceSize: CGSize {
        CGSize(width: bounds.width * activeArea.width,
               height: bounds.height * activeArea.height)
    }

    private var targetDisplayID: CGDirectDisplayID {
        model?.targetDisplayID ?? CGMainDisplayID()
    }
}

@MainActor
private final class SidecarPointerRouter {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var lastLocation: CGPoint?

    func moveAbsolute(normalized: CGPoint, displayID: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(displayID)
        let point = CGPoint(x: bounds.minX + normalized.x * max(bounds.width - 1, 0),
                            y: bounds.minY + normalized.y * max(bounds.height - 1, 0))
        post(.mouseMoved, point: point, button: .left)
    }

    func moveRelative(dx: CGFloat, dy: CGFloat, surfaceSize: CGSize, displayID: CGDirectDisplayID) {
        guard surfaceSize.width > 0, surfaceSize.height > 0 else { return }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let cursor = current()
        let origin = bounds.contains(cursor) ? cursor : CGPoint(x: bounds.midX, y: bounds.midY)
        let point = CGPoint(x: min(max(origin.x + dx / surfaceSize.width * bounds.width * 1.25, bounds.minX), bounds.maxX - 1),
                            y: min(max(origin.y + dy / surfaceSize.height * bounds.height * 1.25, bounds.minY), bounds.maxY - 1))
        post(.mouseMoved, point: point, button: .left)
    }

    func click(down: Bool) { post(down ? .leftMouseDown : .leftMouseUp, point: current(), button: .left) }
    func rightClick(down: Bool) { post(down ? .rightMouseDown : .rightMouseUp, point: current(), button: .right) }

    private func current() -> CGPoint { lastLocation ?? CGEvent(source: nil)?.location ?? .zero }

    private func post(_ type: CGEventType, point: CGPoint, button: CGMouseButton) {
        // Cursor warping alone can make motion look successful while the event server rejects
        // clicks. Check the actual event-posting grant before either action, including mid-session.
        guard CGPreflightPostEventAccess() else { return }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        lastLocation = point
        event.post(tap: .cghidEventTap)
    }
}
