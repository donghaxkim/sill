import AppKit
import ApplicationServices
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
}

struct SidecarDevice: Identifiable, Equatable {
    let name: String
    var id: String { name }
}

/// The Sidecar connection entry points are private on macOS. Keep their use isolated here so the
/// input surface and the rest of Sill do not depend on the private class or its selectors.
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

    func displayID() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { id in
            CGDisplayIsBuiltin(id) == 0 && CGDisplayVendorNumber(id) == 0x6161_706C
        }
    }

    func extendDisplay(_ id: CGDirectDisplayID) throws {
        guard CGDisplayIsInMirrorSet(id) != 0 else { return }
        guard CGDisplayIsAlwaysInMirrorSet(id) == 0 else {
            throw SidecarError("macOS is keeping the iPad in mirror mode.")
        }
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
            throw SidecarError("macOS couldn’t prepare the iPad display for tablet input.")
        }
        let configureResult = CGConfigureDisplayMirrorOfDisplay(configuration, id, kCGNullDirectDisplay)
        guard configureResult == .success else {
            CGCancelDisplayConfiguration(configuration)
            throw SidecarError("macOS couldn’t switch the iPad to Extended Display.")
        }
        guard CGCompleteDisplayConfiguration(configuration, .forSession) == .success else {
            throw SidecarError("macOS couldn’t apply the Extended Display setting.")
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
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
@Observable
final class SidecarTabletModel {
    private enum Key {
        static let selectedDevice = "Sill.tablet.sidecarDevice"
        static let mode = "Sill.tablet.mappingMode"
        static let pencilClick = "Sill.tablet.pencilClick"
        static let fingerInput = "Sill.tablet.fingerInput"
        static let touchClick = "Sill.tablet.touchClick"
        static let activeArea = "Sill.tablet.activeArea"
        static let connectAtLaunch = "Sill.tablet.connectAtLaunch"
    }

    private let defaults: UserDefaults
    private let bridge = SidecarBridge()
    private var surfaceWindow: TabletSurfaceWindowController?
    private var screenObserver: NSObjectProtocol?

    private(set) var devices: [SidecarDevice] = []
    private(set) var connectedDeviceName: String?
    private(set) var isConnecting = false
    private(set) var problem: String?

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
    private(set) var activeArea: TabletActiveArea {
        didSet {
            if let data = try? JSONEncoder().encode(activeArea) { defaults.set(data, forKey: Key.activeArea) }
            updateSurface()
        }
    }
    var connectAtLaunch: Bool {
        didSet { defaults.set(connectAtLaunch, forKey: Key.connectAtLaunch) }
    }

    var isConnected: Bool { connectedDeviceName != nil }
    var supportsSidecarTouch: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }
    var canConnect: Bool { !isConnecting && !selectedDeviceName.isEmpty }
    var statusText: String {
        if isConnecting { return "Connecting to Sidecar…" }
        if let connectedDeviceName { return "Connected to \(connectedDeviceName)" }
        if let problem { return problem }
        return devices.isEmpty ? "No Sidecar iPads found" : "Ready to connect"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedDeviceName = defaults.string(forKey: Key.selectedDevice) ?? ""
        mode = TabletMappingMode(rawValue: defaults.string(forKey: Key.mode) ?? "absolute") ?? .absolute
        pencilContactClick = defaults.object(forKey: Key.pencilClick) as? Bool ?? true
        fingerInputEnabled = defaults.bool(forKey: Key.fingerInput)
        touchClick = defaults.object(forKey: Key.touchClick) as? Bool ?? true
        if let data = defaults.data(forKey: Key.activeArea), let area = try? JSONDecoder().decode(TabletActiveArea.self, from: data) {
            activeArea = area.bounded()
        } else {
            activeArea = .full
        }
        connectAtLaunch = defaults.bool(forKey: Key.connectAtLaunch)
    }

    func start() {
        refreshDevices()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sidecarDisplaysChanged() }
        }
        guard connectAtLaunch else { return }
        if selectedDeviceName.isEmpty, devices.count == 1 { selectedDeviceName = devices[0].name }
        connectSelected()
    }

    func setActiveArea(_ area: TabletActiveArea) {
        activeArea = area.bounded()
    }

    func refreshDevices() {
        do {
            devices = try bridge.devices()
            if selectedDeviceName.isEmpty, devices.count == 1 { selectedDeviceName = devices[0].name }
            if !selectedDeviceName.isEmpty, !devices.contains(where: { $0.name == selectedDeviceName }) {
                problem = "\(selectedDeviceName) isn’t currently available."
            } else if !isConnected {
                problem = nil
            }
        } catch {
            devices = []
            problem = error.localizedDescription
        }
    }

    func connectSelected() {
        guard canConnect else { return }
        Task { await connect(name: selectedDeviceName) }
    }

    func disconnect() {
        let name = connectedDeviceName ?? selectedDeviceName
        guard !name.isEmpty else { return }
        surfaceWindow?.close()
        surfaceWindow = nil
        connectedDeviceName = nil
        Task {
            do { try await bridge.disconnect(name: name) }
            catch { problem = error.localizedDescription }
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func connect(name: String) async {
        guard AXIsProcessTrusted() else {
            problem = "Sill needs Accessibility permission to control the Mac pointer."
            openAccessibilitySettings()
            return
        }
        isConnecting = true
        problem = nil
        defer { isConnecting = false }
        do {
            try await bridge.connect(name: name)
            guard let id = await waitForSidecarDisplayID() else {
                try? await bridge.disconnect(name: name)
                problem = "Sidecar connected, but the iPad display didn’t become available."
                return
            }
            try bridge.extendDisplay(id)
            guard let screen = await waitForScreen(id: id) else {
                try? await bridge.disconnect(name: name)
                problem = "The iPad display didn’t become available in Extended Display mode."
                return
            }
            surfaceWindow?.close()
            surfaceWindow = TabletSurfaceWindowController(screen: screen, model: self)
            connectedDeviceName = name
            selectedDeviceName = name
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func waitForSidecarDisplayID() async -> CGDirectDisplayID? {
        for _ in 0..<50 {
            if let id = bridge.displayID() { return id }
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
        guard let connectedDeviceName else { return }
        guard let id = bridge.displayID(), let screen = screen(for: id) else {
            surfaceWindow?.close()
            surfaceWindow = nil
            self.connectedDeviceName = nil
            problem = "The Sidecar display disconnected."
            return
        }
        surfaceWindow?.move(to: screen)
        self.connectedDeviceName = connectedDeviceName
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
        self.mode = mode
        self.activeArea = activeArea.bounded()
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
        route(event.locationInWindow)
        if pencilClick { router.click(down: true) }
    }
    override func mouseUp(with event: NSEvent) {
        if pencilClick { router.click(down: false) }
    }
    override func mouseDragged(with event: NSEvent) { route(event.locationInWindow) }
    override func rightMouseDown(with event: NSEvent) {
        route(event.locationInWindow)
        router.rightClick(down: true)
    }
    override func rightMouseUp(with event: NSEvent) { router.rightClick(down: false) }

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
            lastTouchPoint = point
            route(point)
        case .changed:
            if mode == .relative, let lastTouchPoint {
                router.moveRelative(dx: point.x - lastTouchPoint.x, dy: lastTouchPoint.y - point.y, surfaceSize: bounds.size)
            } else {
                route(point)
            }
            lastTouchPoint = point
        case .ended, .cancelled, .failed:
            lastTouchPoint = nil
        default: break
        }
    }

    @objc private func directTouchTap(_ recognizer: NSClickGestureRecognizer) {
        guard fingerInputEnabled, recognizer.state == .ended else { return }
        let point = recognizer.location(in: self)
        route(point)
        guard touchClick else { return }
        router.click(down: true)
        router.click(down: false)
    }

    private func route(_ windowPoint: NSPoint) {
        let local = convert(windowPoint, from: nil)
        let u = local.x / max(bounds.width, 1)
        let v = 1 - local.y / max(bounds.height, 1)
        if mode == .absolute {
            guard let normalized = activeArea.normalized(CGPoint(x: u, y: v)) else { return }
            router.moveAbsolute(normalized: normalized)
        } else {
            if let lastPointerPoint {
                router.moveRelative(dx: local.x - lastPointerPoint.x,
                                    dy: lastPointerPoint.y - local.y,
                                    surfaceSize: bounds.size)
            }
        }
        lastPointerPoint = local
    }
}

@MainActor
private final class SidecarPointerRouter {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var lastLocation: CGPoint?

    func moveAbsolute(normalized: CGPoint) {
        let display = CGMainDisplayID()
        let bounds = CGDisplayBounds(display)
        let point = CGPoint(x: bounds.minX + normalized.x * bounds.width,
                            y: bounds.minY + normalized.y * bounds.height)
        post(.mouseMoved, point: point, button: .left)
    }

    func moveRelative(dx: CGFloat, dy: CGFloat, surfaceSize: CGSize) {
        guard surfaceSize.width > 0, surfaceSize.height > 0,
              let current = CGEvent(source: nil)?.location else { return }
        let display = CGDisplayBounds(CGMainDisplayID())
        let point = CGPoint(x: min(max(current.x + dx / surfaceSize.width * display.width * 1.25, display.minX), display.maxX - 1),
                            y: min(max(current.y + dy / surfaceSize.height * display.height * 1.25, display.minY), display.maxY - 1))
        post(.mouseMoved, point: point, button: .left)
    }

    func click(down: Bool) { post(down ? .leftMouseDown : .leftMouseUp, point: current(), button: .left) }
    func rightClick(down: Bool) { post(down ? .rightMouseDown : .rightMouseUp, point: current(), button: .right) }

    private func current() -> CGPoint { CGEvent(source: nil)?.location ?? lastLocation ?? .zero }

    private func post(_ type: CGEventType, point: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        lastLocation = point
        event.post(tap: .cghidEventTap)
    }
}
