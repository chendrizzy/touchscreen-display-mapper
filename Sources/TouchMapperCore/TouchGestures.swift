import CoreGraphics
import Foundation

/// Phone-style touch. Instead of every touch being a mouse press, a touch is
/// read as one of:
/// - a tap: a click where the finger landed;
/// - a pan: a finger that moves before it has rested scrolls what is under it;
/// - a hold: a finger that rests `holdDelay` presses where it landed and drags;
/// - with `pinch`, a zoom: a second tap that moves zooms, dragging down zooms in;
/// - two fingers, on panels that report each finger: a pan, or with `pinch` a
///   zoom, whichever they start doing first. Once one of the two lifts, nothing
///   more happens until every finger has lifted.
///
/// Presses go through `PointerTranslator`, so taps still count up into
/// double-clicks. Without `gestures` every sample goes straight to the
/// translator, exactly as before gestures existed.
public struct TouchGestures {
    /// How far a finger may wander, in points, and still be resting.
    public static let slop: CGFloat = 10
    public static let holdDelay: TimeInterval = 0.5
    /// One-finger zoom per point dragged.
    public static let zoomPerPoint: CGFloat = 0.005
    /// The shortest press posted: a release sent in the same event cycle as
    /// its press is dropped and leaves the button stuck (found by HIDTouch,
    /// github.com/koshi545/HIDTouch, CGEventInjector.swift). A tap's press
    /// goes out at the lift, so its release always waits this long.
    public static let minimumPress: TimeInterval = 0.04
    /// Double-tap radius for fingers, about 7 mm on a 5.6 point/mm panel; a
    /// mouse's 12 points would be 2 mm there.
    public static let tapRadius: CGFloat = 40

    enum State: Equatable {
        case idle
        /// Touching; what the touch is has not shown yet.
        case pending(origin: CGPoint, start: TimeInterval, secondTap: Bool)
        case panning(anchor: CGPoint, last: CGPoint)
        /// A press is held and drags with the finger.
        case pressing
        case zooming(anchor: CGPoint, lastY: CGFloat)
        /// Two fingers; what they do has not shown yet.
        case pair(centroid: CGPoint, spread: CGFloat)
        case pairPanning(anchor: CGPoint, last: CGPoint)
        case pairZooming(anchor: CGPoint, lastSpread: CGFloat)
        /// The gesture is over but a finger still touches.
        case spent
        /// The touch is over; its press waits out `minimumPress` for the release.
        case releasing(until: TimeInterval)
    }

    public let gestures: Bool
    public let pinch: Bool
    private var translator: PointerTranslator
    private(set) var state = State.idle
    /// Where the finger last touched.
    private var latest = CGPoint.zero
    /// When the press now held was posted.
    private var pressedAt: TimeInterval = 0
    private var lastTap: (time: TimeInterval, point: CGPoint)?

    private static let down = PointerSample(buttons: 1, x: 0, y: 0)
    private static let up = PointerSample(buttons: 0, x: 0, y: 0)

    /// `pinch` takes effect only with `gestures`.
    public init(doubleClickInterval: TimeInterval, gestures: Bool, pinch: Bool) {
        translator = gestures
            ? PointerTranslator(doubleClickInterval: doubleClickInterval, doubleClickRadius: Self.tapRadius)
            : PointerTranslator(doubleClickInterval: doubleClickInterval)
        self.gestures = gestures
        self.pinch = gestures && pinch
    }

    /// Whether a touch is in progress (for gestures off: a press is held).
    public var isActive: Bool {
        guard gestures else { return translator.isHolding }
        switch state {
        case .idle, .releasing: return false
        default: return true
        }
    }

    /// When `tick` has something to do even if no report arrives: a resting
    /// finger turning into a hold, or a delayed release.
    public var deadline: TimeInterval? {
        switch state {
        case let .pending(_, start, _): return start + Self.holdDelay
        case let .releasing(until): return until
        default: return nil
        }
    }

    /// One pointer sample: `point` is the sample's place on the display and
    /// `partner` its second finger's. Only the touch (button 0) is read with
    /// gestures; a pen's other buttons are ignored.
    public mutating func step(_ sample: PointerSample, at point: CGPoint, partner: CGPoint?, time: TimeInterval) -> [PointerAction] {
        guard gestures else { return translator.translate(sample, at: point, time: time) }
        guard sample.buttons & 1 != 0 else { return lift(sample, at: point, time: time) }
        var released: [PointerAction] = []
        if case .releasing = state {
            // A new touch landing before the last release went out.
            released = release()
        }
        return released + touch(at: point, partner: partner, time: time)
    }

    public mutating func tick(_ time: TimeInterval) -> [PointerAction] {
        guard let deadline, time >= deadline else { return [] }
        switch state {
        case let .pending(origin, start, _): return hold(origin, start: start, time: time)
        case .releasing: return release()
        default: return []
        }
    }

    /// Ends everything, as if every finger lifted, for a lift that never came.
    /// A touch that had not shown what it is does nothing: a lost lift is
    /// not a tap.
    public mutating func releaseAll() -> [PointerAction] {
        guard gestures else { return translator.releaseAll() }
        defer { state = .idle }
        switch state {
        case let .panning(anchor, _), let .pairPanning(anchor, _):
            return [.pan(dx: 0, dy: 0, at: anchor, .ended)]
        case let .zooming(anchor, _), let .pairZooming(anchor, _):
            return [.magnify(0, at: anchor, .ended)]
        case .pressing, .releasing:
            return translator.releaseAll()
        case .idle, .pending, .pair, .spent:
            return []
        }
    }

    private mutating func touch(at point: CGPoint, partner: CGPoint?, time: TimeInterval) -> [PointerAction] {
        latest = point
        if state == .idle {
            state = .pending(origin: point, start: time, secondTap: followsTap(point, time))
        }
        if case .pending = state, let partner {
            state = .pair(centroid: midpoint(point, partner), spread: distance(point, partner))
            return []
        }
        switch state {
        case let .pending(origin, start, secondTap):
            if time - start >= Self.holdDelay { return hold(origin, start: start, time: time) }
            guard distance(point, origin) > Self.slop else { return [] }
            // Zoom reads vertical motion only; a sideways drag scrolls.
            if secondTap, abs(point.y - origin.y) > abs(point.x - origin.x) {
                state = .zooming(anchor: origin, lastY: point.y)
                return [.move(origin), .magnify((point.y - origin.y) * Self.zoomPerPoint, at: origin, .began)]
            }
            state = .panning(anchor: origin, last: point)
            return [.move(origin), .pan(dx: point.x - origin.x, dy: point.y - origin.y, at: origin, .began)]

        case let .panning(anchor, last):
            guard point != last else { return [] }
            state = .panning(anchor: anchor, last: point)
            return [.pan(dx: point.x - last.x, dy: point.y - last.y, at: anchor, .changed)]

        case .pressing:
            return translator.translate(Self.down, at: point, time: time)

        case let .zooming(anchor, lastY):
            guard point.y != lastY else { return [] }
            state = .zooming(anchor: anchor, lastY: point.y)
            return [.magnify((point.y - lastY) * Self.zoomPerPoint, at: anchor, .changed)]

        case let .pair(centroid, spread):
            guard let partner else { state = .spent; return [] }
            let (now, apart) = (midpoint(point, partner), distance(point, partner))
            if pinch, abs(apart - spread) > Self.slop {
                state = .pairZooming(anchor: centroid, lastSpread: apart)
                return [.move(centroid), .magnify(apart / max(spread, 1) - 1, at: centroid, .began)]
            }
            guard distance(now, centroid) > Self.slop else { return [] }
            state = .pairPanning(anchor: centroid, last: now)
            return [.move(centroid), .pan(dx: now.x - centroid.x, dy: now.y - centroid.y, at: centroid, .began)]

        case let .pairPanning(anchor, last):
            guard let partner else { state = .spent; return [.pan(dx: 0, dy: 0, at: anchor, .ended)] }
            let now = midpoint(point, partner)
            guard now != last else { return [] }
            state = .pairPanning(anchor: anchor, last: now)
            return [.pan(dx: now.x - last.x, dy: now.y - last.y, at: anchor, .changed)]

        case let .pairZooming(anchor, lastSpread):
            guard let partner else { state = .spent; return [.magnify(0, at: anchor, .ended)] }
            let apart = distance(point, partner)
            guard apart != lastSpread else { return [] }
            state = .pairZooming(anchor: anchor, lastSpread: apart)
            return [.magnify(apart / max(lastSpread, 1) - 1, at: anchor, .changed)]

        case .idle, .spent, .releasing:
            return []
        }
    }

    /// No finger touching: the end of a touch, or a pen hovering.
    private mutating func lift(_ sample: PointerSample, at point: CGPoint, time: TimeInterval) -> [PointerAction] {
        switch state {
        case .idle:
            return translator.translate(PointerSample(buttons: 0, x: sample.x, y: sample.y, wheel: sample.wheel),
                                        at: point, time: time)
        case .releasing:
            return []
        case let .pending(origin, start, _):
            // A tap clicks where it landed, pressed as of the landing so a
            // double tap counts up like a double-click.
            lastTap = (start, origin)
            pressedAt = time
            state = .releasing(until: time + Self.minimumPress)
            return translator.translate(Self.down, at: origin, time: start)
        case .pressing:
            if time - pressedAt < Self.minimumPress {
                state = .releasing(until: pressedAt + Self.minimumPress)
                return []
            }
            state = .idle
            return translator.translate(Self.up, at: point, time: time)
        default:
            return releaseAll()
        }
    }

    private mutating func hold(_ origin: CGPoint, start: TimeInterval, time: TimeInterval) -> [PointerAction] {
        state = .pressing
        pressedAt = time
        return translator.translate(Self.down, at: origin, time: start)
            + translator.translate(Self.down, at: latest, time: time)
    }

    private mutating func release() -> [PointerAction] {
        state = .idle
        return translator.releaseAll()
    }

    private func followsTap(_ point: CGPoint, _ time: TimeInterval) -> Bool {
        guard pinch, let lastTap else { return false }
        return time - lastTap.time <= translator.doubleClickInterval
            && distance(point, lastTap.point) <= translator.doubleClickRadius
    }
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
}
