import CoreGraphics
import Foundation
import Testing
@testable import TouchMapperCore

private let touching = PointerSample(buttons: 1, x: 0, y: 0)
private let lifted = PointerSample(buttons: 0, x: 0, y: 0)
private let o = CGPoint(x: 2500, y: 900)

private func at(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: o.x + dx, y: o.y + dy) }

private func gestures(pinch: Bool = false) -> TouchGestures {
    TouchGestures(doubleClickInterval: 0.5, gestures: true, pinch: pinch)
}

private extension TouchGestures {
    /// A finger at `point`, and a second one at `partner`.
    mutating func finger(_ point: CGPoint, _ time: TimeInterval, partner: CGPoint? = nil) -> [PointerAction] {
        step(touching, at: point, partner: partner, time: time)
    }

    /// Every finger lifted. Lift reports often carry zeros for a position.
    mutating func allLifted(_ time: TimeInterval) -> [PointerAction] {
        step(lifted, at: .zero, partner: nil, time: time)
    }

    /// A completed tap at `point`, its release already sent.
    mutating func tap(_ point: CGPoint, _ time: TimeInterval) {
        _ = finger(point, time)
        _ = allLifted(time + 0.0625)
        _ = tick(deadline!)
    }
}

struct TouchGesturesTests {
    @Test func withoutGesturesEverySampleGoesStraightToTheTranslator() {
        var plain = TouchGestures(doubleClickInterval: 0.5, gestures: false, pinch: true)
        var translator = PointerTranslator(doubleClickInterval: 0.5)
        let script: [(PointerSample, CGPoint, TimeInterval)] = [
            (touching, o, 0), (touching, at(30, 0), 0.0625), (lifted, .zero, 0.125),
            (touching, o, 0.25), (lifted, o, 0.3125),
            (touching, at(5, 5), 0.375), (lifted, at(5, 5), 0.4375),
            (PointerSample(buttons: 0, x: 0, y: 0, wheel: -2), o, 0.5),
            (PointerSample(buttons: 2, x: 0, y: 0), o, 0.5625),
        ]
        for (sample, point, time) in script {
            #expect(plain.step(sample, at: point, partner: at(99, 99), time: time)
                    == translator.translate(sample, at: point, time: time))
            #expect(plain.isActive == translator.isHolding)
            #expect(plain.deadline == nil)
            #expect(plain.tick(time + 1).isEmpty)
        }
        #expect(plain.releaseAll() == translator.releaseAll())
        #expect(!plain.pinch)
    }

    @Test func aTapClicksWhereTheFingerLandedAndReleasesAfterAShortPress() {
        var g = gestures()
        #expect(g.finger(o, 0).isEmpty)
        #expect(g.isActive)
        #expect(g.finger(at(4, -3), 0.0625).isEmpty)
        #expect(g.allLifted(0.125) == [.move(o), .down(.left, o, clickCount: 1)])
        #expect(!g.isActive)
        let release = try! #require(g.deadline)
        #expect(release == 0.125 + TouchGestures.minimumPress)
        #expect(g.tick(release - 0.001).isEmpty)
        #expect(g.tick(release) == [.up(.left, o, clickCount: 1)])
        #expect(g.deadline == nil)
    }

    @Test func nothingButANewTouchCutsATapsPressShort() {
        var g = gestures()
        _ = g.finger(o, 0)
        _ = g.allLifted(0.0625)
        // Hover in between is dropped.
        #expect(g.step(lifted, at: at(100, 0), partner: nil, time: 0.07).isEmpty)
        // A new touch sends the release first, then starts over.
        #expect(g.finger(at(200, 0), 0.09) == [.up(.left, o, clickCount: 1)])
        #expect(g.isActive)
        #expect(g.deadline == 0.09 + TouchGestures.holdDelay)
    }

    @Test func tapsOnNearlyTheSameSpotCountUpLikeDoubleClicks() {
        var g = gestures()
        g.tap(o, 0)
        // 27 points off: beyond a mouse's 12, within a finger's radius.
        let near = at(25, 10)
        _ = g.finger(near, 0.25)
        #expect(g.allLifted(0.3125) == [.move(near), .down(.left, near, clickCount: 2)])
    }

    @Test func aFingerThatMovesBeforeRestingPansWhatIsUnderIt() {
        var g = gestures()
        _ = g.finger(o, 0)
        #expect(g.finger(at(0, 8), 0.0625).isEmpty)
        #expect(g.finger(at(3, 12), 0.125) == [.move(o), .pan(dx: 3, dy: 12, at: o, .began)])
        #expect(g.finger(at(3, 30), 0.1875) == [.pan(dx: 0, dy: 18, at: o, .changed)])
        #expect(g.finger(at(3, 30), 0.25).isEmpty)
        // A pan never turns into a hold.
        #expect(g.deadline == nil)
        #expect(g.finger(at(3, 30), 0.75).isEmpty)
        // The lift report's position is not a last step.
        #expect(g.allLifted(0.8125) == [.pan(dx: 0, dy: 0, at: o, .ended)])
        #expect(!g.isActive)
    }

    @Test func aFingerThatRestsPressesWhereItLandedThenDrags() {
        var g = gestures()
        _ = g.finger(o, 0)
        #expect(g.deadline == TouchGestures.holdDelay)
        #expect(g.finger(at(2, 2), 0.25).isEmpty)
        #expect(g.finger(at(2, 2), 0.5) == [.move(o), .down(.left, o, clickCount: 1), .drag(.left, at(2, 2))])
        #expect(g.deadline == nil)
        // Now it drags however far it goes.
        #expect(g.finger(at(80, 0), 0.5625) == [.drag(.left, at(80, 0))])
        #expect(g.allLifted(0.625) == [.up(.left, at(80, 0), clickCount: 1)])
        #expect(!g.isActive)
    }

    /// For panels that send nothing while a finger rests.
    @Test func aRestingFingerTurnsIntoAHoldOnTick() {
        var g = gestures()
        _ = g.finger(o, 0)
        #expect(g.tick(0.4375).isEmpty)
        #expect(g.tick(0.5) == [.move(o), .down(.left, o, clickCount: 1)])
        #expect(g.tick(0.75).isEmpty)
        #expect(g.isActive)
    }

    @Test func withPinchASecondTapThatMovesZoomsAndDraggingDownZoomsIn() {
        var g = gestures(pinch: true)
        g.tap(o, 0)
        let second = at(5, 0)
        #expect(g.finger(second, 0.25).isEmpty)
        #expect(g.finger(at(5, 20), 0.3125)
                == [.move(second), .magnify(20 * TouchGestures.zoomPerPoint, at: second, .began)])
        #expect(g.finger(at(5, 10), 0.375) == [.magnify(-10 * TouchGestures.zoomPerPoint, at: second, .changed)])
        #expect(g.allLifted(0.4375) == [.magnify(0, at: second, .ended)])
        #expect(!g.isActive)
    }

    @Test func withPinchASecondTapThatStaysStillIsADoubleClick() {
        var g = gestures(pinch: true)
        g.tap(o, 0)
        _ = g.finger(o, 0.25)
        #expect(g.allLifted(0.3125) == [.move(o), .down(.left, o, clickCount: 2)])
    }

    @Test func withPinchASecondTapThatRestsDragsAsADoubleClick() {
        var g = gestures(pinch: true)
        g.tap(o, 0)
        _ = g.finger(o, 0.25)
        #expect(g.tick(0.75) == [.move(o), .down(.left, o, clickCount: 2)])
    }

    @Test func withPinchASecondTapThatMovesSidewaysPans() {
        var g = gestures(pinch: true)
        g.tap(o, 0)
        _ = g.finger(o, 0.25)
        #expect(g.finger(at(20, 5), 0.3125) == [.move(o), .pan(dx: 20, dy: 5, at: o, .began)])
    }

    @Test func aHoldLiftedAtOnceStillLastsTheMinimumPress() {
        var g = gestures()
        _ = g.finger(o, 0)
        #expect(g.tick(0.5) == [.move(o), .down(.left, o, clickCount: 1)])
        #expect(g.allLifted(0.5).isEmpty)
        #expect(!g.isActive)
        #expect(g.deadline == 0.5 + TouchGestures.minimumPress)
        #expect(g.tick(g.deadline!) == [.up(.left, o, clickCount: 1)])
    }

    @Test func withoutPinchASecondTapThatMovesStillPans() {
        var g = gestures()
        g.tap(o, 0)
        _ = g.finger(o, 0.25)
        #expect(g.finger(at(0, 20), 0.3125) == [.move(o), .pan(dx: 0, dy: 20, at: o, .began)])
    }

    @Test func aDistantOrLateSecondTapPansEvenWithPinch() {
        var g = gestures(pinch: true)
        g.tap(o, 0)
        let far = at(60, 0)
        _ = g.finger(far, 0.25)
        #expect(g.finger(CGPoint(x: far.x, y: far.y + 20), 0.3125) == [.move(far), .pan(dx: 0, dy: 20, at: far, .began)])
        _ = g.allLifted(0.375)
        // A pan is not a tap: the last tap is still the one at 0 s.
        _ = g.finger(o, 1)
        #expect(g.finger(at(0, 20), 1.0625) == [.move(o), .pan(dx: 0, dy: 20, at: o, .began)])
    }

    @Test func twoFingersPanByTheirMidpoint() {
        var g = gestures()
        _ = g.finger(at(-50, 0), 0)
        #expect(g.finger(at(-50, 0), 0.0625, partner: at(50, 0)).isEmpty)
        #expect(g.deadline == nil)
        #expect(g.finger(at(-50, 8), 0.125, partner: at(50, 8)).isEmpty)
        #expect(g.finger(at(-50, 12), 0.1875, partner: at(50, 12)) == [.move(o), .pan(dx: 0, dy: 12, at: o, .began)])
        #expect(g.finger(at(-40, 20), 0.25, partner: at(60, 20)) == [.pan(dx: 10, dy: 8, at: o, .changed)])
        // One finger lifting ends the pan, and the other then does nothing.
        #expect(g.finger(at(-40, 20), 0.3125) == [.pan(dx: 0, dy: 0, at: o, .ended)])
        #expect(g.finger(at(40, 90), 0.375).isEmpty)
        #expect(g.finger(at(40, 90), 1.5).isEmpty)
        #expect(g.isActive)
        #expect(g.allLifted(1.5625).isEmpty)
        #expect(!g.isActive)
    }

    @Test func withPinchTwoFingersSpreadingZoom() {
        var g = gestures(pinch: true)
        #expect(g.finger(at(-50, 0), 0, partner: at(50, 0)).isEmpty)
        // Spread 100 -> 112 -> 140 points; typed first, which older compilers need.
        let opened: CGFloat = 112 / 100 - 1, widened: CGFloat = 140 / 112 - 1
        #expect(g.finger(at(-56, 0), 0.0625, partner: at(56, 0)) == [.move(o), .magnify(opened, at: o, .began)])
        #expect(g.finger(at(-70, 0), 0.125, partner: at(70, 0)) == [.magnify(widened, at: o, .changed)])
        #expect(g.allLifted(0.1875) == [.magnify(0, at: o, .ended)])
    }

    @Test func withoutPinchTwoFingersSpreadingDoNothing() {
        var g = gestures()
        _ = g.finger(at(-50, 0), 0, partner: at(50, 0))
        #expect(g.finger(at(-90, 0), 0.0625, partner: at(90, 0)).isEmpty)
        #expect(g.allLifted(0.125).isEmpty)
    }

    @Test func aSecondFingerLiftingBeforeAnythingHappenedEndsTheTouchQuietly() {
        var g = gestures()
        _ = g.finger(o, 0, partner: at(80, 0))
        #expect(g.finger(o, 0.0625).isEmpty)
        #expect(g.finger(o, 0.75).isEmpty)
        #expect(g.allLifted(0.8125).isEmpty)
    }

    @Test func aSecondFingerJoiningAOneFingerGestureIsIgnored() {
        var g = gestures()
        _ = g.finger(o, 0)
        _ = g.finger(at(0, 20), 0.0625)
        #expect(g.finger(at(0, 30), 0.125, partner: at(200, 0)) == [.pan(dx: 0, dy: 10, at: o, .changed)])
    }

    @Test func aLostLiftEndsWhateverWasGoingOn() {
        var pan = gestures()
        _ = pan.finger(o, 0)
        _ = pan.finger(at(0, 20), 0.0625)
        #expect(pan.releaseAll() == [.pan(dx: 0, dy: 0, at: o, .ended)])
        #expect(!pan.isActive)

        var hold = gestures()
        _ = hold.finger(o, 0)
        _ = hold.tick(0.5)
        #expect(hold.releaseAll() == [.up(.left, o, clickCount: 1)])

        var zoom = gestures(pinch: true)
        _ = zoom.finger(o, 0, partner: at(100, 0))
        _ = zoom.finger(o, 0.0625, partner: at(120, 0))
        #expect(zoom.releaseAll() == [.magnify(0, at: at(50, 0), .ended)])

        var tap = gestures()
        _ = tap.finger(o, 0)
        _ = tap.allLifted(0.0625)
        #expect(tap.releaseAll() == [.up(.left, o, clickCount: 1)])
        #expect(tap.deadline == nil)

        // A touch that had not shown what it is: no click.
        var pending = gestures()
        _ = pending.finger(o, 0)
        #expect(pending.releaseAll().isEmpty)
        #expect(!pending.isActive)
        #expect(pending.deadline == nil)
    }

    @Test func aHoveringPenStillMovesThePointer() {
        var g = gestures()
        #expect(g.step(lifted, at: o, partner: nil, time: 0) == [.move(o)])
        // Only the tip counts with gestures: a barrel button alone is hover.
        #expect(g.step(PointerSample(buttons: 2, x: 0, y: 0), at: at(1, 0), partner: nil, time: 0.0625) == [.move(at(1, 0))])
        #expect(!g.isActive)
    }
}
