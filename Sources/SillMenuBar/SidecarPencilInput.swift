import AppKit
import CoreGraphics

/// Replace Sidecar's Pencil events before WindowServer dispatches them. Handling them in
/// NSView is too late: the native event has already moved the cursor onto the iPad.
@MainActor
final class SidecarPencilMapper {
    static let eventTag: Int64 = 0x484954504144
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var deviceID: Int64?
    private var lastSourcePoint: CGPoint?
    private var lastLocation: CGPoint?
    private var pressedButton: CGMouseButton?
    private var deltaAccumulator = MouseDeltaAccumulator()

    func transform(_ event: CGEvent, sourceBounds: CGRect, geometry: TabletSurfaceGeometry,
                   targetBounds: CGRect, mode: TabletMappingMode, clicks: Bool,
                   currentLocation: () -> CGPoint) -> CGEvent? {
        guard event.getIntegerValueField(.eventSourceUserData) != Self.eventTag else { return event }
        let subtype = event.getIntegerValueField(.mouseEventSubtype)
        let isProximity = event.type == .tabletProximity || subtype == 2
        let isTablet = event.type == .tabletPointer || subtype == 1 || isProximity
        guard isTablet else { return event }
        let sourcePoint = tabletSourcePoint(for: event, subtype: subtype)
        let incomingDevice = event.getIntegerValueField(isProximity ? .tabletProximityEventDeviceID : .tabletEventDeviceID)
        let isCapturedDevice = deviceID != nil && incomingDevice == deviceID
        guard sourceBounds.contains(sourcePoint) || isCapturedDevice else { return event }

        // Proximity and standalone tablet samples accompany the mouse events. Forwarding any
        // of them would reintroduce the iPad cursor position or switch the target to tablet input.
        if isProximity {
            if event.getIntegerValueField(.tabletProximityEventEnterProximity) == 0 {
                return endInput().first
            }
            return nil
        }
        guard event.type != .tabletPointer else { return nil }
        if incomingDevice != 0 { deviceID = incomingDevice }

        let local = CGPoint(x: geometry.bounds.minX + sourcePoint.x - sourceBounds.minX,
                            y: geometry.bounds.maxY - (sourcePoint.y - sourceBounds.minY))
        let normalized = geometry.normalized(local)
        let isDown = event.type == .leftMouseDown || event.type == .rightMouseDown
        let isUp = event.type == .leftMouseUp || event.type == .rightMouseUp
        let isRight = event.type == .rightMouseDown || event.type == .rightMouseDragged || event.type == .rightMouseUp

        let button: CGMouseButton = isRight ? .right : .left
        if isDown {
            lastSourcePoint = nil
            if mode == .relative { lastLocation = nil }
        }
        if isUp {
            lastSourcePoint = nil
            guard pressedButton == button, let lastLocation else { return nil }
            pressedButton = nil
            return mouseEvent(isRight ? .rightMouseUp : .leftMouseUp, at: lastLocation,
                              original: event)
        }
        guard let normalized, targetBounds.width > 0, targetBounds.height > 0 else {
            lastSourcePoint = nil
            return nil
        }

        let point: CGPoint
        if mode == .absolute {
            point = TabletSurfaceGeometry.destination(normalized, in: targetBounds)
        } else {
            let cursor = lastLocation ?? currentLocation()
            let origin = targetBounds.contains(cursor) ? cursor : CGPoint(x: targetBounds.midX, y: targetBounds.midY)
            if let previous = lastSourcePoint {
                point = CGPoint(
                    x: min(max(origin.x + (local.x - previous.x) / geometry.activeRect.width * targetBounds.width * 1.25,
                               targetBounds.minX), targetBounds.maxX - 1),
                    y: min(max(origin.y + (previous.y - local.y) / geometry.activeRect.height * targetBounds.height * 1.25,
                               targetBounds.minY), targetBounds.maxY - 1))
            } else { point = origin }
            lastSourcePoint = local
        }
        let previousLocation = lastLocation ?? currentLocation()
        lastLocation = point
        let delta = deltaAccumulator.take(CGPoint(x: point.x - previousLocation.x,
                                                  y: point.y - previousLocation.y))
        let type: CGEventType
        if isDown && clicks {
            // A Pencil contact owns one button. Ignore a conflicting press until it is released.
            guard pressedButton == nil || pressedButton == button else { return nil }
            pressedButton = button
            type = isRight ? .rightMouseDown : .leftMouseDown
        } else {
            type = pressedButton == .left ? .leftMouseDragged : pressedButton == .right ? .rightMouseDragged : .mouseMoved
        }
        return mouseEvent(type, at: point, delta: delta, original: event)
    }

    /// Disconnects and setting changes must release buttons even if no Pencil-up arrives.
    func endInput() -> [CGEvent] {
        var events: [CGEvent] = []
        if let lastLocation, let pressedButton,
           let event = mouseEvent(pressedButton == .right ? .rightMouseUp : .leftMouseUp, at: lastLocation) {
            events.append(event)
        }
        deviceID = nil
        lastSourcePoint = nil
        lastLocation = nil
        pressedButton = nil
        deltaAccumulator.reset()
        return events
    }

    /// WindowServer clamps the mouse location to the focused game window while a game captures
    /// the pointer. The raw tablet fields keep the actual Pencil position, so prefer them for
    /// tablet-point events and fall back to the mouse location when a driver omits them.
    private func tabletSourcePoint(for event: CGEvent, subtype: Int64) -> CGPoint {
        guard subtype == 1 || event.type == .tabletPointer else { return event.location }
        let x = event.getDoubleValueField(.tabletEventPointX)
        let y = event.getDoubleValueField(.tabletEventPointY)
        guard x != 0 || y != 0 else { return event.location }
        return CGPoint(x: x, y: y)
    }

    private func mouseEvent(_ type: CGEventType, at point: CGPoint,
                            delta: (x: Int64, y: Int64) = (0, 0), original: CGEvent? = nil) -> CGEvent? {
        let right = type == .rightMouseDown || type == .rightMouseDragged || type == .rightMouseUp
        guard let result = CGEvent(mouseEventSource: eventSource, mouseType: type,
                                   mouseCursorPosition: point, mouseButton: right ? .right : .left) else { return nil }
        result.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        result.setIntegerValueField(.mouseEventDeltaX, value: delta.x)
        result.setIntegerValueField(.mouseEventDeltaY, value: delta.y)
        if let original {
            result.flags = original.flags
            if type != .mouseMoved {
                result.setIntegerValueField(.mouseEventClickState, value: original.getIntegerValueField(.mouseEventClickState))
            }
        }
        return result
    }
}

/// SDL, and therefore osu!'s High Precision Mouse, reads relative motion from the event's
/// integer deltas instead of its cursor position. Keep fractional movement across samples so
/// slow tablet strokes are not rounded away.
struct MouseDeltaAccumulator {
    private var remainderX: CGFloat = 0
    private var remainderY: CGFloat = 0

    mutating func take(_ movement: CGPoint) -> (x: Int64, y: Int64) {
        let x = remainderX + movement.x
        let y = remainderY + movement.y
        let deltaX = Int64(x.rounded())
        let deltaY = Int64(y.rounded())
        remainderX = x - CGFloat(deltaX)
        remainderY = y - CGFloat(deltaY)
        return (deltaX, deltaY)
    }

    mutating func reset() {
        remainderX = 0
        remainderY = 0
    }
}

/// The run loop and callback both execute on the main thread, alongside the surface geometry.
/// Only pointer/tablet events are observed; keyboards and unrelated pointing devices pass through.
@MainActor
final class SidecarPencilEventTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let transform: (CGEvent) -> CGEvent?
    private let interrupted: () -> Void
    private let send: (CGEvent) -> Void

    init(transform: @escaping (CGEvent) -> CGEvent?, interrupted: @escaping () -> Void,
         send: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.transform = transform
        self.interrupted = interrupted
        self.send = send
    }

    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                   .rightMouseDown, .rightMouseUp, .rightMouseDragged, .tabletPointer, .tabletProximity]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        // The session tap is too late: native Pencil-down has already established a drag,
        // suppressing AppKit hover even when subsequent events are converted to mouseMoved.
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<SidecarPencilEventTap>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.interrupted()
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return owner.process(event).map { Unmanaged.passUnretained($0) }
            }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return false }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    func process(_ event: CGEvent) -> CGEvent? {
        guard let mapped = transform(event) else { return nil }
        guard mapped !== event else { return event }
        // Consume the source and inject one standard mouse event through HID. WindowServer
        // updates the visible cursor and chooses the app under it, including hover tracking.
        // Reusing Sidecar's event dispatch or warping ahead of it does not provide those semantics.
        send(mapped)
        return nil
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }
}
