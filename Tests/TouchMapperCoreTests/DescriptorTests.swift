import CoreGraphics
import Testing
@testable import TouchMapperCore

func bytes(_ hex: String) -> [UInt8] {
    var result: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        result.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return result
}

func decoders(_ hex: String) throws -> [PointerDecoder] {
    PointerDecoder.decoders(for: try HIDReportDescriptor(bytes(hex)))
}

/// A report: `id`, then a zeroed body of `length` bytes with `set` applied.
func report(id: UInt8, length: Int, set: [Int: UInt8]) -> [UInt8] {
    var body = [UInt8](repeating: 0, count: length)
    for (index, value) in set { body[index] = value }
    return [id] + body
}

func contacts(_ decoder: PointerDecoder, _ report: [UInt8]) throws -> ContactReport {
    guard case let .contacts(contacts) = try #require(decoder.decode(report)) else {
        Issue.record("expected a digitizer report")
        return ContactReport(contacts: [], count: nil)
    }
    return contacts
}

struct KeyGoDescriptorTests {
    @Test func mouseInterfaceDecodesTheCapturedReport() throws {
        let found = try decoders(KeyGoFixtures.keygoMouse)
        #expect(found.count == 1)
        let mouse = try #require(found.first)
        #expect(mouse.reportID == 7)
        #expect(mouse.source == .mouse)
        #expect(!mouse.isTouchScreen)
        #expect(mouse.rangeDescription == "X 0...16383, Y 0...9599")

        // Captured from the real panel in observe mode: a press, then its lift.
        #expect(mouse.decode(bytes("0701662ad81300")) == .mouse(PointerSample(buttons: 1, x: 10854.0 / 16383, y: 5080.0 / 9599)))
        #expect(mouse.decode(bytes("0700662ad81300")) == .mouse(PointerSample(buttons: 0, x: 10854.0 / 16383, y: 5080.0 / 9599)))
    }

    @Test func touchScreenInterfaceDecodesTenSlots() throws {
        let touch = try #require(try decoders(KeyGoFixtures.keygoTouchScreen).first { $0.reportID == 0x0D })
        #expect(touch.source == .digitizer)
        #expect(touch.isTouchScreen)
        #expect(touch.contactSlots == 10)
        #expect(touch.rangeDescription == "X 0...16383, Y 0...9599")
        // Slot 0: tip on, contact id 1, X 0x2000, Y 0x1000. After the ten
        // 5-byte slots come Scan Time (16 bits) and Contact Count (byte 52).
        let decoded = try contacts(touch, report(id: 0x0D, length: 53, set: [0: 0x11, 2: 0x20, 4: 0x10, 52: 1]))
        #expect(decoded.contacts.count == 10)
        #expect(decoded.contacts.first == Contact(id: 1, touching: true, x: 8192.0 / 16383, y: 4096.0 / 9599))
        #expect(decoded.count == 1)
        #expect(decoded.scanTime == 0)
        var assembler = ScanAssembler()
        #expect(assembler.add(decoded) == [Contact(id: 1, touching: true, x: 8192.0 / 16383, y: 4096.0 / 9599)])
    }

    @Test func vendorInterfaceIsNotAPointer() throws {
        #expect(try decoders(KeyGoFixtures.keygoVendor).isEmpty)
    }

    @Test func reportsFromOtherIDsAreNotDecoded() throws {
        let mouse = try #require(try decoders(KeyGoFixtures.keygoMouse).first)
        #expect(mouse.decode(bytes("0d0100000000")) == nil)
    }
}

struct OtherPanelDescriptorTests {
    @Test func wingcoolExposesPenAndTouchScreen() throws {
        let found = try decoders(OtherPanelFixtures.wingcoolDigitizer)
        #expect(found.map(\.reportID) == [0x06, 0x0D])
        #expect(found.allSatisfy { $0.source == .digitizer })
        #expect(found.map(\.contactSlots) == [1, 10])
        // Only the finger stream proves the panel reports fingers itself; a
        // pen tap must not silence the mouse emulation fingers arrive on.
        #expect(found.map(\.isTouchScreen) == [false, true])
        #expect(found.allSatisfy { $0.rangeDescription == "X 0...16383, Y 0...9599" })
    }

    @Test func wingcoolCapturedTwoFingerReportDecodes() throws {
        let touch = try #require(try decoders(OtherPanelFixtures.wingcoolDigitizer).first { $0.reportID == 0x0D })
        let decoded = try contacts(touch, bytes(OtherPanelFixtures.wingcoolTwoFingerReport))
        // The capture lists contact 1 before contact 0, so slot order is not
        // contact order. Its contact count byte was not recorded (zero).
        #expect(Array(decoded.contacts.prefix(2)) == [
            Contact(id: 1, touching: true, x: 7034.0 / 16383, y: 8229.0 / 9599),
            Contact(id: 0, touching: true, x: 10610.0 / 16383, y: 5659.0 / 9599),
        ])
        #expect(decoded.count == 0)

        // With the count the panel would have sent (2), the scan holds both
        // contacts, and a fresh two-finger landing presses the lowest identity.
        var withCount = decoded
        withCount.count = 2
        var assembler = ScanAssembler()
        var pointer = TouchPointer()
        _ = pointer.step([]) { true }
        let assembled = assembler.add(withCount)
        let scan = try #require(assembled)
        #expect(scan.count == 2)
        // The other finger landed with it, so it is reported as the partner.
        #expect(pointer.step(scan) { true } == PointerSample(buttons: 1, x: 10610.0 / 16383, y: 5659.0 / 9599,
                                                             partner: CGPoint(x: 7034.0 / 16383, y: 8229.0 / 9599)))
    }

    @Test func ilitekTouchScreenMatchesAnIndependentDecode() throws {
        let found = try decoders(OtherPanelFixtures.ilitekTouchScreen)
        #expect(found.count == 1)
        let touch = try #require(found.first)
        #expect(touch.reportID == 4)
        #expect(touch.source == .digitizer)
        #expect(touch.contactSlots == 10)
        #expect(touch.rangeDescription == "X 0...8192, Y 0...8192")
        // Slot 0: contact id in bits 0-5, tip switch bit 6, X at bit 8, Y at
        // bit 24; contact count at bit 432 (byte 54).
        let down = try contacts(touch, report(id: 4, length: 63, set: [0: 0x40, 2: 0x10, 4: 0x20, 54: 1]))
        #expect(down.contacts.first == Contact(id: 0, touching: true, x: 0.5, y: 1.0))
        #expect(down.count == 1)
        let lifted = try contacts(touch, report(id: 4, length: 63, set: [0: 0x00, 2: 0x10, 4: 0x20, 54: 1]))
        #expect(lifted.contacts.first == Contact(id: 0, touching: false, x: 0.5, y: 1.0))
    }
}

/// Small hand-written descriptors for rules no captured fixture exercises.
struct DescriptorRuleTests {
    /// An absolute mouse without report IDs: reports carry no ID byte.
    let unnumberedMouse = "05010902a101" + "0509190129031500250175019503810275059501810305010930093115002610277510950281" + "02c0"

    @Test func devicesWithoutReportIDsAreDecodedFromTheFirstByte() throws {
        let mouse = try #require(try decoders(unnumberedMouse).first)
        #expect(mouse.reportID == 0)
        // Buttons 1, X 5000, Y 10000 (of 0...10000).
        #expect(mouse.decode([0x01, 0x88, 0x13, 0x10, 0x27]) == .mouse(PointerSample(buttons: 1, x: 0.5, y: 1.0)))
    }

    @Test func touchPadsAreNeverPinnedToADisplay() throws {
        // Digitizer / Touch Pad > Finger: tip switch, absolute X/Y.
        let touchPad = "050d0905a101" + "0922a102" + "09421500250175019501810275079501810305010930093115002610277510950281" + "02c0c0"
        #expect(try decoders(touchPad).isEmpty)
    }

    @Test func relativeMiceAreNotPointersToPin() throws {
        let relative = "05010902a101" + "05091901290315002501750195038102750595018103050109300931158125" + "7f750895028106c0"
        #expect(try decoders(relative).isEmpty)
    }

    @Test func aUsagePageDeclaredAfterItsUsagesStillApplies() throws {
        // Touch Screen > Finger: tip switch, then "09 30 09 31 05 01": X and Y
        // declared while the page is still Digitizer.
        let descriptor = "050d0904a101" + "0922a102" + "094215002501750195018102750795018103"
            + "0930093105011500261027751095028102" + "c0c0"
        let touch = try #require(try decoders(descriptor).first)
        #expect(touch.contactSlots == 1)
        #expect(touch.rangeDescription == "X 0...10000, Y 0...10000")
    }

    @Test func mixedPageUsageListsKeepTheirPages() throws {
        // "05 0D 09 42 05 01 09 30" in one main item: tip switch stays Digitizer.
        let parsed = try HIDReportDescriptor(bytes("050d09420501093015002501750195028102"))
        #expect(parsed.inputFields.map { [$0.usagePage, $0.usage] } == [[0x0D, 0x42], [0x01, 0x30]])
    }

    @Test func aUsageRangeEndingAtTheTopDoesNotTrap() throws {
        // Extended Usage Minimum/Maximum 0xFFFFFFFE...0xFFFFFFFF, two fields.
        let parsed = try HIDReportDescriptor(bytes("1bfeffffff2bffffffff15002501750195028102"))
        #expect(parsed.inputFields.map(\.usage) == [0xFFFE, 0xFFFF])
    }

    @Test func signedFieldsAreSignExtended() throws {
        let field = HIDField(reportID: 0, bitOffset: 8, bitSize: 8, usagePage: 1, usage: 0x38,
                             logicalMinimum: -127, logicalMaximum: 127, isRelative: true, collections: [])
        #expect(field.value(in: [0x00, 0xFF]) == -1)
        #expect(field.value(in: [0x00]) == nil)
    }

    @Test func malformedDescriptorsAreRejected() {
        #expect(throws: HIDDescriptorError.self) { try HIDReportDescriptor([0x05]) }
        #expect(throws: HIDDescriptorError.self) { try HIDReportDescriptor([0xC0]) }
        #expect(throws: HIDDescriptorError.self) { try HIDReportDescriptor([0xB4]) }
    }

    @Test func absurdReportCountsAreRejectedNotLoopedOver() {
        // Usage X, Report Size 1, Report Count 65536 (4-byte item), Input.
        #expect(throws: HIDDescriptorError.self) { try HIDReportDescriptor(bytes("05010930750197000001008102")) }
    }

    @Test func pushAndPopRestoreGlobals() throws {
        // Usage page Generic Desktop, push, switch to Button, pop, then usage X.
        let descriptor = try HIDReportDescriptor(bytes("0501a101a40509b409301500250f750895018102c0"))
        #expect(descriptor.inputFields.first?.usagePage == 1)
        #expect(descriptor.inputFields.first?.usage == 0x30)
    }
}

struct FeatureFieldTests {
    /// Report 3 has a 16-bit input and a one-byte feature: 4 bits of padding,
    /// then a 4-bit Device Mode.
    static let inputAndFeature = "050d090ea1018503" + "0956150026ff00751095018102" + "75049501b103" + "0952250a7504b102" + "c0"

    @Test func featureReportsAreLaidOutApartFromInputReports() throws {
        let descriptor = try HIDReportDescriptor(bytes(Self.inputAndFeature))
        #expect(descriptor.inputFields.map(\.bitOffset) == [0])
        let feature = try #require(descriptor.featureFields.first)
        #expect(descriptor.featureFields.count == 1)
        #expect((feature.reportID, feature.usage, feature.bitOffset, feature.bitSize) == (3, 0x52, 4, 4))
        #expect(descriptor.featureReportLengths == [3: 1])
    }

    @Test func writingAFieldLeavesItsNeighboursAlone() {
        let field = HIDField(reportID: 0, bitOffset: 3, bitSize: 4, usagePage: 1, usage: 0x30,
                             logicalMinimum: -8, logicalMaximum: 7, isRelative: false, collections: [])
        var body: [UInt8] = [0x87, 0x00]
        #expect(field.write(-1, into: &body))
        #expect(body == [0xFF, 0x00])
        #expect(field.value(in: body) == -1)
        #expect(field.write(2, into: &body))
        #expect(body == [0x97, 0x00])
        #expect(field.value(in: body) == 2)
    }

    @Test func writesOutsideTheFieldOrItsRangeAreRefused() {
        let field = HIDField(reportID: 0, bitOffset: 6, bitSize: 4, usagePage: 1, usage: 0x30,
                             logicalMinimum: 0, logicalMaximum: 10, isRelative: false, collections: [])
        var short: [UInt8] = [0x00]
        #expect(!field.write(1, into: &short))
        var body: [UInt8] = [0x00, 0x00]
        #expect(!field.write(11, into: &body))
        #expect(!field.write(-1, into: &body))
        #expect(body == [0x00, 0x00])
    }
}
