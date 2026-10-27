import AppKit
import CoreGraphics

var checks = 0
var failures = 0
func check(_ value: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !value { failures += 1; print("FAIL line \(line): \(message)") }
}
func near(_ a: CGPoint?, _ b: CGPoint, tolerance: CGFloat = 0.00001) -> Bool {
    guard let a else { return false }
    return abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
}

// The user's actual Sidecar dimensions and saved, asymmetric active area.
let area = TabletActiveArea(x: 0.472, y: 0.128, width: 0.406, height: 0.388)
let surfaceBounds = CGRect(x: 0, y: 0, width: 1180, height: 742)
let target = CGRect(x: 499, y: 1440, width: 1512, height: 982)

for bounds in [surfaceBounds, CGRect(x: 11, y: 23, width: 820, height: 1180)] {
    for active in [TabletActiveArea.full, area, TabletActiveArea(x: 0.8, y: 0.1, width: 0.1, height: 0.7)] {
        let geometry = TabletSurfaceGeometry(bounds: bounds, activeArea: active)
        let rect = geometry.activeRect
        let cases: [(CGPoint, CGPoint)] = [
            (CGPoint(x: rect.minX, y: rect.maxY), .zero),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: 1, y: 0)),
            (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: 0, y: 1)),
            (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: 1, y: 1)),
            (CGPoint(x: rect.midX, y: rect.midY), CGPoint(x: 0.5, y: 0.5))
        ]
        for (point, normalized) in cases {
            check(near(geometry.normalized(point), normalized), "outline corner/center maps exactly: \(point)")
        }
        for point in [CGPoint(x: rect.minX - 0.01, y: rect.midY),
                      CGPoint(x: rect.maxX + 0.01, y: rect.midY),
                      CGPoint(x: rect.midX, y: rect.minY - 0.01),
                      CGPoint(x: rect.midX, y: rect.maxY + 0.01)] {
            check(geometry.normalized(point) == nil, "outside the outline is inactive")
        }
    }
}
for display in [target, CGRect(x: -2560, y: -1440, width: 2560, height: 1440)] {
    check(near(TabletSurfaceGeometry.destination(.zero, in: display), display.origin), "top-left display origin")
    check(near(TabletSurfaceGeometry.destination(CGPoint(x: 1, y: 1), in: display),
               CGPoint(x: display.maxX - 1, y: display.maxY - 1)), "bottom-right stays on selected display")
}

// Finger gestures still use the mouse-event router. Its output stays separate from Pencil's
// HID filter and never changes the real cursor in these checks.
MainActor.assumeIsolated {
    _ = NSApplication.shared
    var events: [CGEvent] = []
    var permitted = true
    let router = SidecarPointerRouter(displayBounds: { _ in target },
                                      readLocation: { CGPoint(x: target.midX, y: target.midY) },
                                      canPost: { permitted }, send: { events.append($0) })
    router.moveAbsolute(normalized: .zero, displayID: 1)
    check(near(events.last?.location, target.origin), "touch router maps top-left")
    router.click(down: true)
    router.moveAbsolute(normalized: CGPoint(x: 1, y: 1), displayID: 1)
    router.click(down: false)
    check(events.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp],
          "touch router emits a complete drag sequence")
    check(near(events.last?.location, CGPoint(x: target.maxX - 1, y: target.maxY - 1)), "touch release uses final location")
    permitted = false
    let count = events.count
    router.moveAbsolute(normalized: .zero, displayID: 1)
    check(events.count == count, "revoked posting access sends no events")
}

// Replay the native Sidecar event sequence captured during the flicker. The old NSView path
// forwarded each source event and posted a second movement, leaving the cursor on the iPad
// between samples. The filter must replace it with one ordinary mouse event on the Mac.
MainActor.assumeIsolated {
    let mapper = SidecarPencilMapper()
    let source = CGRect(x: -1180, y: 0, width: 1180, height: 742)
    let geometry = TabletSurfaceGeometry(bounds: surfaceBounds, activeArea: area)
    func pencil(_ type: CGEventType, at point: CGPoint, subtype: Int64 = 1) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)!
        event.type = type
        event.setIntegerValueField(.mouseEventSubtype, value: subtype)
        event.setIntegerValueField(.tabletEventDeviceID, value: 48906)
        return event
    }
    @MainActor func map(_ event: CGEvent, clicks: Bool = false, mode: TabletMappingMode = .absolute) -> CGEvent? {
        mapper.transform(event, sourceBounds: source, geometry: geometry, targetBounds: target,
                         mode: mode, clicks: clicks, currentLocation: { CGPoint(x: target.midX, y: target.midY) })
    }
    let raw = CGPoint(x: -329, y: 238.99)
    let down = pencil(.leftMouseDown, at: raw)
    let mappedDown = map(down)
    check(mappedDown !== down, "Pencil replaces the incoming event instead of forwarding it")
    check(mappedDown?.type == .mouseMoved, "Pencil-down with clicks off is one normal mouse move")
    check(mappedDown?.getIntegerValueField(.mouseEventSubtype) == 0, "mapped events no longer have tablet semantics")
    check(mappedDown.map { target.contains($0.location) } == true, "contact never reaches the iPad display")
    if let mappedDown { check(map(mappedDown) === mappedDown, "mapped events cannot feed back into the mapper") }
    for step in 0..<500 {
        let point = CGPoint(x: -329 + CGFloat(step % 40), y: 238.99 + CGFloat(step % 20))
        let result = map(pencil(.leftMouseDragged, at: point))
        check(result?.type == .mouseMoved && result.map { target.contains($0.location) } == true,
              "continuous stroke sample \(step) has exactly one target-display event")
    }
    check(map(pencil(.leftMouseUp, at: raw)) == nil, "lift with clicks off never sends the source position")
    let secondContact = map(pencil(.leftMouseDown, at: CGPoint(x: -500, y: 200)))
    check(secondContact?.location != mappedDown?.location, "new contact jumps to its new absolute position")
    check(map(pencil(.tabletPointer, at: raw, subtype: 0)) == nil, "standalone tablet sample cannot move the cursor back")
    check(map(pencil(.tabletProximity, at: raw, subtype: 0)) == nil, "standalone proximity cannot move the cursor back")
    check(map(pencil(.mouseMoved, at: raw, subtype: 2)) == nil, "embedded proximity cannot move the cursor back")
    check(map(pencil(.leftMouseDragged, at: CGPoint(x: -1100, y: 700))) == nil,
          "Pencil outside active area is consumed, not forwarded to iPad")
    _ = mapper.endInput()
    let ordinaryMouse = pencil(.mouseMoved, at: raw, subtype: 0)
    check(map(ordinaryMouse) === ordinaryMouse, "ordinary mouse input is unchanged even on the iPad")
    let otherTablet = pencil(.leftMouseDragged, at: target.origin)
    otherTablet.setIntegerValueField(.tabletEventDeviceID, value: 42)
    check(map(otherTablet) === otherTablet, "another tablet on another display is unchanged")

    let click = map(pencil(.leftMouseDown, at: raw), clicks: true)
    let drag = map(pencil(.leftMouseDragged, at: raw), clicks: true)
    let up = map(pencil(.leftMouseUp, at: CGPoint(x: -1100, y: 700)), clicks: true)
    check([click?.type, drag?.type, up?.type] == [.leftMouseDown, .leftMouseDragged, .leftMouseUp],
          "contact-click sends one down/drag/up sequence")
    check(near(up?.location, drag!.location), "lifting outside the area releases on the target display")
    _ = map(pencil(.leftMouseDown, at: raw), clicks: true)
    let releases = mapper.endInput()
    check(releases.count == 1 && releases[0].type == .leftMouseUp, "disconnect releases a captured click")
    check(mapper.endInput().isEmpty, "capture cleanup is idempotent")
    let relativeStart = map(pencil(.leftMouseDown, at: raw), mode: .relative)
    let relativeMove = map(pencil(.leftMouseDragged, at: CGPoint(x: raw.x + 10, y: raw.y + 10)), mode: .relative)
    check(relativeStart.map { target.contains($0.location) } == true, "trackpad contact stays on target display")
    check(relativeMove!.location.x > relativeStart!.location.x && relativeMove!.location.y > relativeStart!.location.y,
          "relative Pencil motion preserves both axes")
}
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
