import CoreGraphics
import Testing
@testable import TouchMapperCore

private func touch(_ id: Int?, at x: Double = 0.5, confident: Bool = true) -> Contact {
    Contact(id: id, touching: true, confident: confident, x: x, y: x)
}

private func lifted(_ id: Int?) -> Contact {
    Contact(id: id, touching: false, x: 0, y: 0)
}

private func pressed(at x: Double, partner: Double? = nil) -> PointerSample {
    PointerSample(buttons: 1, x: x, y: x, partner: partner.map { CGPoint(x: $0, y: $0) })
}
private func released(at x: Double) -> PointerSample { PointerSample(buttons: 0, x: x, y: x) }

/// A pointer whose first (seeding) scan had nothing touching.
private func seededPointer() -> TouchPointer {
    var pointer = TouchPointer()
    _ = pointer.step([]) { true }
    return pointer
}

struct ScanAssemblerTests {
    @Test func reportsWithoutACountAreCompleteScans() {
        var assembler = ScanAssembler()
        #expect(assembler.add(ContactReport(contacts: [touch(0)], count: nil)) == [touch(0)])
    }

    @Test func aScanSpreadOverSeveralReportsIsJudgedOnlyWhenComplete() {
        var assembler = ScanAssembler()
        // Three contacts, two slots per report (Windows hybrid mode).
        #expect(assembler.add(ContactReport(contacts: [touch(2), touch(1)], count: 3)) == nil)
        #expect(assembler.isPending)
        #expect(assembler.add(ContactReport(contacts: [touch(0), lifted(0)], count: 0)) == [touch(2), touch(1), touch(0)])
        #expect(!assembler.isPending)
    }

    @Test func slotsBeyondTheCountAreIgnored() {
        var assembler = ScanAssembler()
        #expect(assembler.add(ContactReport(contacts: [touch(4), lifted(0), lifted(0)], count: 1)) == [touch(4)])
    }

    @Test func aZeroCountWithNothingPendingIsAnEmptyScan() {
        var assembler = ScanAssembler()
        #expect(assembler.add(ContactReport(contacts: [lifted(0)], count: 0)) == [])
    }

    @Test func aZeroCountReportPaddingTheLastScanIsDropped() {
        var assembler = ScanAssembler()
        #expect(assembler.add(ContactReport(contacts: [touch(0)], count: 1, scanTime: 5)) == [touch(0)])
        #expect(assembler.add(ContactReport(contacts: [lifted(0)], count: 0, scanTime: 5)) == nil)
        #expect(assembler.add(ContactReport(contacts: [lifted(0)], count: 0, scanTime: 6)) == [])
    }

    @Test func aNewCountAbandonsAnUnfinishedScan() {
        var assembler = ScanAssembler()
        #expect(assembler.add(ContactReport(contacts: [touch(2), touch(1)], count: 3)) == nil)
        #expect(assembler.add(ContactReport(contacts: [touch(0)], count: 1)) == [touch(0)])
    }
}

struct TouchPointerTests {
    @Test func theFirstScanOnlySeedsHistory() {
        var pointer = TouchPointer()
        #expect(pointer.step([touch(0)]) { true } == nil)
        #expect(pointer.step([touch(0)]) { true } == nil)
    }

    /// Review finding: an idle digitizer sends nothing, so its first scan
    /// after a quiet period is a real tap and must press.
    @Test func aFirstScanFromAnIdlePanelIsAnOnset() {
        var pointer = TouchPointer(panelWasIdle: true)
        #expect(pointer.step([touch(0, at: 0.2)]) { true } == pressed(at: 0.2))
    }

    /// Review finding: a finger landing in the scan where the driver lifts
    /// must still be able to press (one scan later).
    @Test func aFingerLandingAsTheDriverLiftsStillGetsItsOnset() {
        var pointer = seededPointer()
        _ = pointer.step([touch(0, at: 0.2)]) { true }
        #expect(pointer.step([touch(1, at: 0.7)]) { true } == released(at: 0.2))
        #expect(pointer.step([touch(1, at: 0.7)]) { true } == pressed(at: 0.7))
    }

    @Test func anOnsetPressesAndALiftReleasesWhereTheFingerLastWas() {
        var pointer = seededPointer()
        #expect(pointer.step([touch(0, at: 0.2)]) { true } == pressed(at: 0.2))
        #expect(pointer.step([touch(0, at: 0.3)]) { true } == pressed(at: 0.3))
        #expect(pointer.step([lifted(0)]) { true } == released(at: 0.3))
        #expect(!pointer.isPressed)
    }

    @Test func aContactMissingFromAScanHasLifted() {
        var pointer = seededPointer()
        _ = pointer.step([touch(3, at: 0.2)]) { true }
        #expect(pointer.step([]) { true } == released(at: 0.2))
    }

    @Test func aSecondFingerNeverMovesThePointerAndIsReportedAsItsPartner() {
        var pointer = seededPointer()
        _ = pointer.step([touch(0, at: 0.2)]) { true }
        // Finger 1 lands, listed first.
        #expect(pointer.step([touch(1, at: 0.8), touch(0, at: 0.2)]) { true } == pressed(at: 0.2, partner: 0.8))
        #expect(pointer.step([touch(1, at: 0.7), touch(0, at: 0.2)]) { true } == pressed(at: 0.2, partner: 0.7))
        #expect(pointer.step([lifted(1), touch(0, at: 0.2)]) { true } == pressed(at: 0.2))
    }

    @Test func aPartnerThatLiftsIsNotReplacedByAFingerLandingInTheSameScan() {
        var pointer = seededPointer()
        _ = pointer.step([touch(0, at: 0.2)]) { true }
        _ = pointer.step([touch(0, at: 0.2), touch(1, at: 0.8)]) { true }
        #expect(pointer.step([touch(0, at: 0.2), lifted(1), touch(2, at: 0.6)]) { true } == pressed(at: 0.2))
        // Finger 2 was touching before this scan, so it is no longer an onset.
        #expect(pointer.step([touch(0, at: 0.2), touch(2, at: 0.6)]) { true } == pressed(at: 0.2))
    }

    @Test func aContactRestingBeforeTheTouchOrAPalmIsNeverAPartner() {
        // Contact 9 was already resting when the tool started.
        var pointer = TouchPointer()
        _ = pointer.step([touch(9, at: 0.9)]) { true }
        #expect(pointer.step([touch(9, at: 0.9), touch(0, at: 0.2)]) { true } == pressed(at: 0.2))
        #expect(pointer.step([touch(9, at: 0.9), touch(0, at: 0.2), touch(4, at: 0.5, confident: false)]) { true }
                == pressed(at: 0.2))
        // The palm turning confident is no onset either.
        #expect(pointer.step([touch(9, at: 0.9), touch(0, at: 0.2), touch(4, at: 0.5)]) { true } == pressed(at: 0.2))
    }

    @Test func releaseAllForgetsThePartner() {
        var pointer = seededPointer()
        _ = pointer.step([touch(0, at: 0.2)]) { true }
        _ = pointer.step([touch(0, at: 0.2), touch(1, at: 0.8)]) { true }
        _ = pointer.releaseAll()
        // Finger 1 now drives; a remembered partner would be itself.
        #expect(pointer.step([touch(1, at: 0.8)]) { true } == pressed(at: 0.8))
    }

    @Test func contactsWithoutIdentitiesNeverReportAPartner() {
        var pointer = seededPointer()
        #expect(pointer.step([touch(nil, at: 0.2), touch(nil, at: 0.8)]) { true } == pressed(at: 0.2))
        #expect(pointer.step([touch(nil, at: 0.2), touch(nil, at: 0.8)]) { true } == pressed(at: 0.2))
    }

    @Test func aPartnerTurningPalmIsDropped() {
        var pointer = seededPointer()
        _ = pointer.step([touch(0, at: 0.2)]) { true }
        #expect(pointer.step([touch(0, at: 0.2), touch(1, at: 0.8)]) { true } == pressed(at: 0.2, partner: 0.8))
        #expect(pointer.step([touch(0, at: 0.2), touch(1, at: 0.8, confident: false)]) { true } == pressed(at: 0.2))
        #expect(pointer.step([touch(0, at: 0.2), touch(1, at: 0.8)]) { true } == pressed(at: 0.2))
    }

    /// Review finding: after the driving finger lifts, a palm that rested the
    /// whole time must not become a press.
    @Test func aRestingContactNeverBecomesAPressLater() {
        var pointer = seededPointer()
        _ = pointer.step([touch(0, at: 0.2)]) { true }
        _ = pointer.step([touch(0, at: 0.2), touch(1, at: 0.9)]) { true }
        #expect(pointer.step([touch(1, at: 0.9)]) { true } == released(at: 0.2))
        #expect(pointer.step([touch(1, at: 0.9)]) { true } == nil)
        // Once it lifts and lands again, it is a real onset.
        #expect(pointer.step([]) { true } == nil)
        #expect(pointer.step([touch(1, at: 0.9)]) { true } == pressed(at: 0.9))
    }

    @Test func aNewFingerLandingBesideARestingPalmStillPresses() {
        var pointer = seededPointer()
        _ = pointer.step([touch(5, at: 0.9, confident: false)]) { true }
        #expect(pointer.step([touch(5, at: 0.9, confident: false), touch(6, at: 0.3)]) { true } == pressed(at: 0.3))
    }

    @Test func palmsNeverPressEvenWhenTheyTurnConfident() {
        var pointer = seededPointer()
        #expect(pointer.step([touch(0, confident: false)]) { true } == nil)
        #expect(pointer.step([touch(0)]) { true } == nil)
    }

    @Test func aDriverFlaggedAsAPalmReleases() {
        var pointer = seededPointer()
        _ = pointer.step([touch(0, at: 0.2)]) { true }
        #expect(pointer.step([touch(0, at: 0.4, confident: false)]) { true } == released(at: 0.2))
    }

    /// Review finding: a touch refused at its onset (display absent) must not
    /// wait for a lift, and must never press later.
    @Test func aRefusedOnsetIsNeverGrantedLater() {
        var pointer = seededPointer()
        #expect(pointer.step([touch(0)]) { false } == nil)
        #expect(pointer.step([touch(0)]) { true } == nil)
        #expect(!pointer.isPressed)
    }

    @Test func mayPressIsAskedOnlyAtAnOnset() {
        var pointer = seededPointer()
        var asked = 0
        _ = pointer.step([touch(0)]) { asked += 1; return true }
        _ = pointer.step([touch(0)]) { asked += 1; return true }
        _ = pointer.step([touch(0), touch(1)]) { asked += 1; return true }
        #expect(asked == 1)
    }

    @Test func simultaneousOnsetsPressTheLowestIdentity() {
        var pointer = seededPointer()
        #expect(pointer.step([touch(7, at: 0.7), touch(2, at: 0.2)]) { true } == pressed(at: 0.2, partner: 0.7))
    }

    @Test func withoutIdentitiesANewPressNeedsEveryContactLifted() {
        var pointer = seededPointer()
        #expect(pointer.step([touch(nil, at: 0.2)]) { true } == pressed(at: 0.2))
        #expect(pointer.step([]) { true } == released(at: 0.2))
        #expect(pointer.step([touch(nil, at: 0.4)]) { true } == pressed(at: 0.4))
    }

    @Test func releaseAllEndsATouchAsIfEverythingLifted() {
        var pointer = seededPointer()
        _ = pointer.step([touch(0, at: 0.2)]) { true }
        #expect(pointer.releaseAll() == released(at: 0.2))
        #expect(!pointer.isTouching)
        #expect(pointer.releaseAll() == nil)
    }

    /// Review finding: a scan spread over several reports used to release and
    /// re-press the driving finger every scan (a click storm).
    @Test func hybridScansNeverStormClicks() {
        var assembler = ScanAssembler()
        var pointer = seededPointer()
        var samples: [PointerSample] = []
        func feed(_ report: ContactReport) {
            if let scan = assembler.add(report), let sample = pointer.step(scan, mayPress: { true }) {
                samples.append(sample)
            }
        }
        feed(ContactReport(contacts: [touch(0, at: 0.2), lifted(0)], count: 1))
        for _ in 0..<5 {
            // Three fingers, two slots per report; the driving finger is in
            // the continuation report.
            feed(ContactReport(contacts: [touch(2, at: 0.8), touch(1, at: 0.6)], count: 3))
            feed(ContactReport(contacts: [touch(0, at: 0.2), lifted(0)], count: 0))
        }
        // Fingers 1 and 2 landed during the touch; finger 2 (listed first)
        // became the partner. The driver is never released or re-pressed.
        #expect(samples.dropFirst().allSatisfy { $0 == pressed(at: 0.2, partner: 0.8) })
        #expect(samples.first == pressed(at: 0.2))
        #expect(samples.count == 6)
    }
}
