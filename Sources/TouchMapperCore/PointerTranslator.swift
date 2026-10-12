import CoreGraphics
import Foundation

public enum MouseButton: Int, CaseIterable {
    case left = 0, right = 1, middle = 2

    var mask: UInt8 { 1 << UInt8(rawValue) }
}

/// Where a continuous gesture is, as macOS scroll and gesture events say it.
public enum GesturePhase: Equatable {
    case began, changed, ended
}

/// A mouse event to synthesize, in global display coordinates.
public enum PointerAction: Equatable {
    case move(CGPoint)
    case down(MouseButton, CGPoint, clickCount: Int)
    case drag(MouseButton, CGPoint)
    case up(MouseButton, CGPoint, clickCount: Int)
    case scroll(lines: Int)
    /// Scrolls what is under `at` so it follows a finger that moved (dx, dy)
    /// points (y grows downward).
    case pan(dx: CGFloat, dy: CGFloat, at: CGPoint, GesturePhase)
    /// Zooms what is under `at` by this fraction of its size since the last
    /// step (0.1 is 10% larger).
    case magnify(CGFloat, at: CGPoint, GesturePhase)
}

/// Turns successive pointer samples into the mouse events macOS expects:
/// a move before each press, drags while a button is held, and a click count
/// that grows for repeated taps on the same spot.
public struct PointerTranslator {
    public var doubleClickInterval: TimeInterval
    public var doubleClickRadius: CGFloat

    private var held: UInt8 = 0
    private var lastPoint: CGPoint?
    private var pressCount: [MouseButton: Int] = [:]
    private var lastPress: [MouseButton: (time: TimeInterval, point: CGPoint, count: Int)] = [:]

    public init(doubleClickInterval: TimeInterval, doubleClickRadius: CGFloat = 12) {
        self.doubleClickInterval = doubleClickInterval
        self.doubleClickRadius = doubleClickRadius
    }

    /// Whether a press has been posted and not yet released.
    public var isHolding: Bool { held != 0 }

    public mutating func translate(_ sample: PointerSample, at point: CGPoint, time: TimeInterval) -> [PointerAction] {
        var actions: [PointerAction] = []
        let previous = held
        let current = sample.buttons & 0b111
        let touchStarts = previous == 0 && current != 0
        // The report that lifts the last button often carries no meaningful
        // position (many panels send zeros), so that release lands where the
        // press was last held instead of being dragged there.
        let liftsAll = previous != 0 && current == 0

        // Every touch places the cursor before pressing, even on the exact
        // spot the last touch ended, since another device may have moved it.
        if !liftsAll, point != lastPoint || touchStarts {
            if let dragging = MouseButton.allCases.first(where: { previous & $0.mask != 0 }) {
                actions.append(.drag(dragging, point))
            } else {
                actions.append(.move(point))
            }
            lastPoint = point
        }

        let releasePoint = liftsAll ? (lastPoint ?? point) : point
        for button in MouseButton.allCases where previous & button.mask != 0 && current & button.mask == 0 {
            actions.append(.up(button, releasePoint, clickCount: pressCount[button] ?? 1))
        }

        for button in MouseButton.allCases where previous & button.mask == 0 && current & button.mask != 0 {
            let count = nextClickCount(button, at: point, time: time)
            pressCount[button] = count
            lastPress[button] = (time, point, count)
            actions.append(.down(button, point, clickCount: count))
        }

        held = current
        if sample.wheel != 0 {
            actions.append(.scroll(lines: sample.wheel))
        }
        return actions
    }

    /// Releases every held button, for when the panel disappears mid-touch.
    public mutating func releaseAll() -> [PointerAction] {
        guard let point = lastPoint else { held = 0; return [] }
        let actions = MouseButton.allCases
            .filter { held & $0.mask != 0 }
            .map { PointerAction.up($0, point, clickCount: pressCount[$0] ?? 1) }
        held = 0
        return actions
    }

    private func nextClickCount(_ button: MouseButton, at point: CGPoint, time: TimeInterval) -> Int {
        guard let last = lastPress[button],
              time - last.time <= doubleClickInterval,
              hypot(point.x - last.point.x, point.y - last.point.y) <= doubleClickRadius
        else { return 1 }
        return last.count + 1
    }
}
