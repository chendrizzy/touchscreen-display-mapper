import CoreGraphics
import Testing
@testable import TouchMapperCore

struct DisplayMapperTests {
    // A 1920x720 display to the right of the main one.
    let keygo = CGRect(x: 2056, y: 609, width: 1920, height: 720)

    @Test func cornersLandOnTheDisplayEdges() {
        #expect(DisplayMapper.point(x: 0, y: 0, onto: keygo) == CGPoint(x: 2056, y: 609))
        #expect(DisplayMapper.point(x: 1, y: 1, onto: keygo) == CGPoint(x: 3975, y: 1328))
    }

    @Test func outOfRangeValuesAreClamped() {
        #expect(DisplayMapper.point(x: 1.3, y: 1.2, onto: keygo) == CGPoint(x: 3975, y: 1328))
        #expect(DisplayMapper.point(x: -0.1, y: -0.1, onto: keygo) == CGPoint(x: 2056, y: 609))
    }

    @Test func centreMapsToCentre() {
        let p = DisplayMapper.point(x: 0.5, y: 0.5, onto: keygo)
        #expect(abs(p.x - (2056 + 1919.0 / 2)) < 1)
        #expect(abs(p.y - (609 + 719.0 / 2)) < 1)
    }

    @Test func worksForDisplaysLeftOfOrAboveMain() {
        let above = CGRect(x: 343, y: -1440, width: 3440, height: 1440)
        #expect(DisplayMapper.point(x: 0, y: 0, onto: above) == CGPoint(x: 343, y: -1440))
    }
}

struct PointerTranslatorTests {
    let p1 = CGPoint(x: 2100, y: 700)
    let p2 = CGPoint(x: 2300, y: 900)

    func translator() -> PointerTranslator { PointerTranslator(doubleClickInterval: 0.5) }
    func down(_ b: UInt8 = 1) -> PointerSample { PointerSample(buttons: b, x: 0, y: 0) }
    let up = PointerSample(buttons: 0, x: 0, y: 0)

    @Test func tapMovesThenClicksAtTheTouchedPoint() {
        var t = translator()
        #expect(t.translate(down(), at: p1, time: 0) == [.move(p1), .down(.left, p1, clickCount: 1)])
        #expect(t.translate(up, at: p1, time: 0.1) == [.up(.left, p1, clickCount: 1)])
    }

    @Test func movementWhileHeldIsADrag() {
        var t = translator()
        _ = t.translate(down(), at: p1, time: 0)
        #expect(t.translate(down(), at: p2, time: 0.05) == [.drag(.left, p2)])
        #expect(t.translate(up, at: p2, time: 0.1) == [.up(.left, p2, clickCount: 1)])
    }

    /// Many panels put zeros (or stale values) in the report that lifts.
    @Test func releaseLandsWhereThePressWasLastHeldNotAtTheLiftReportsPosition() {
        var t = translator()
        _ = t.translate(down(), at: p1, time: 0)
        _ = t.translate(down(), at: p2, time: 0.05)
        let corner = CGPoint(x: 0, y: 0)
        #expect(t.translate(up, at: corner, time: 0.1) == [.up(.left, p2, clickCount: 1)])
        // The next touch still places the cursor first.
        #expect(t.translate(down(), at: p1, time: 2) == [.move(p1), .down(.left, p1, clickCount: 1)])
    }

    @Test func repeatedTapsOnTheSameSpotCountUp() {
        var t = translator()
        _ = t.translate(down(), at: p1, time: 0)
        _ = t.translate(up, at: p1, time: 0.05)
        #expect(t.translate(down(), at: p1, time: 0.2) == [.move(p1), .down(.left, p1, clickCount: 2)])
        #expect(t.translate(up, at: p1, time: 0.25) == [.up(.left, p1, clickCount: 2)])
        let nearby = CGPoint(x: p1.x + 5, y: p1.y - 5)
        #expect(t.translate(down(), at: nearby, time: 0.4) == [.move(nearby), .down(.left, nearby, clickCount: 3)])
    }

    @Test func slowOrDistantTapsStartOver() {
        var t = translator()
        _ = t.translate(down(), at: p1, time: 0)
        _ = t.translate(up, at: p1, time: 0.05)
        #expect(t.translate(down(), at: p1, time: 2) == [.move(p1), .down(.left, p1, clickCount: 1)])
        _ = t.translate(up, at: p1, time: 2.05)
        #expect(t.translate(down(), at: p2, time: 2.1) == [.move(p2), .down(.left, p2, clickCount: 1)])
    }

    @Test func rightButtonAndWheel() {
        var t = translator()
        #expect(t.translate(down(0b010), at: p1, time: 0) == [.move(p1), .down(.right, p1, clickCount: 1)])
        #expect(t.translate(PointerSample(buttons: 0, x: 0, y: 0, wheel: -2), at: p1, time: 0.1)
                == [.up(.right, p1, clickCount: 1), .scroll(lines: -2)])
    }

    @Test func unchangedReportProducesNothing() {
        var t = translator()
        _ = t.translate(down(), at: p1, time: 0)
        #expect(t.translate(down(), at: p1, time: 0.01).isEmpty)
    }

    @Test func releaseAllLetsGoOfHeldButtons() {
        var t = translator()
        #expect(t.releaseAll().isEmpty)
        _ = t.translate(down(), at: p1, time: 0)
        #expect(t.releaseAll() == [.up(.left, p1, clickCount: 1)])
        #expect(t.releaseAll().isEmpty)
    }

    @Test func isHoldingTracksPostedPresses() {
        var t = translator()
        #expect(!t.isHolding)
        _ = t.translate(down(), at: p1, time: 0)
        #expect(t.isHolding)
        _ = t.translate(up, at: p1, time: 0.1)
        #expect(!t.isHolding)
        _ = t.translate(down(), at: p1, time: 0.2)
        _ = t.releaseAll()
        #expect(!t.isHolding)
    }

    @Test func aTouchOnTheSpotTheLastOneEndedStillPlacesTheCursor() {
        var t = translator()
        _ = t.translate(down(), at: p1, time: 0)
        _ = t.translate(up, at: p1, time: 0.1)
        #expect(t.translate(down(), at: p1, time: 5) == [.move(p1), .down(.left, p1, clickCount: 1)])
    }

    @Test func liftAfterAForcedReleasePostsNoSecondUp() {
        var t = translator()
        _ = t.translate(down(), at: p1, time: 0)
        _ = t.releaseAll()
        #expect(t.translate(up, at: p1, time: 0.6).isEmpty)
    }
}
