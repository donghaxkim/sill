import Foundation
import CoreGraphics

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

/// One AppKit (bottom-left) rectangle for the visible outline and every input path.
struct TabletSurfaceGeometry {
    let bounds: CGRect
    let activeArea: TabletActiveArea

    var tabletRect: CGRect { bounds.insetBy(dx: 16, dy: 16) }

    var activeRect: CGRect {
        let rect = tabletRect
        return CGRect(x: rect.minX + rect.width * activeArea.x,
                      y: rect.minY + rect.height * (1 - activeArea.y - activeArea.height),
                      width: rect.width * activeArea.width,
                      height: rect.height * activeArea.height)
    }

    func normalized(_ point: CGPoint) -> CGPoint? {
        let rect = activeRect
        guard rect.width > 0, rect.height > 0,
              point.x >= rect.minX, point.x <= rect.maxX,
              point.y >= rect.minY, point.y <= rect.maxY else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width,
                       y: (rect.maxY - point.y) / rect.height)
    }

    static func destination(_ normalized: CGPoint, in display: CGRect) -> CGPoint {
        CGPoint(x: display.minX + normalized.x * max(display.width - 1, 0),
                y: display.minY + normalized.y * max(display.height - 1, 0))
    }
}
