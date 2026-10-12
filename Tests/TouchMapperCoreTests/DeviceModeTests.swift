import Testing
@testable import TouchMapperCore

private func deviceMode(_ hex: String) throws -> DeviceMode? {
    DeviceMode(try HIDReportDescriptor(bytes(hex)))
}

struct DeviceModeTests {
    @Test func theKeyGoDeclaresItInFeatureReport0x21() throws {
        let mode = try #require(try deviceMode(KeyGoFixtures.keygoTouchScreen))
        #expect(mode.reportID == 0x21)
        // ID byte, Device Mode, Device Identifier.
        #expect(mode.reportLength == 3)
        #expect(mode.value(in: [0x21, 0x00, 0x05]) == DeviceMode.mouse)
        #expect(mode.report(DeviceMode.multiInput) == [0x21, 0x02, 0x00])
        #expect(mode.report(DeviceMode.mouse) == [0x21, 0x00, 0x00])
    }

    @Test func theWingCoolPanelDeclaresTheSameSetting() throws {
        let mode = try #require(try deviceMode(OtherPanelFixtures.wingcoolDigitizer))
        #expect(mode.reportID == 0x21)
        #expect(mode.reportLength == 3)
        #expect(mode.value(in: [0x21, 0x02, 0x00]) == DeviceMode.multiInput)
    }

    @Test func panelsAndInterfacesWithoutItHaveNone() throws {
        #expect(try deviceMode(OtherPanelFixtures.ilitekTouchScreen) == nil)
        #expect(try deviceMode(KeyGoFixtures.keygoMouse) == nil)
    }

    @Test func theModeIsPlacedWhereTheDescriptorSays() throws {
        let mode = try #require(try deviceMode(FeatureFieldTests.inputAndFeature))
        #expect(mode.reportLength == 2)
        #expect(mode.value(in: [0x03, 0x2F]) == 2)
        #expect(mode.report(DeviceMode.multiInput) == [0x03, 0x20])
    }

    @Test func aBufferThatIsNotTheReportIsRefused() throws {
        let mode = try #require(try deviceMode(KeyGoFixtures.keygoTouchScreen))
        // What the KeyGo answers a read with: the first bytes of the request.
        #expect(mode.value(in: [0xA1, 0x01, 0x21]) == nil)
        #expect(mode.value(in: [0x22, 0x02, 0x00]) == nil)
        #expect(mode.value(in: [0x21, 0x02]) == nil)
        #expect(mode.value(in: [0x21, 0x02, 0x00, 0x00]) == nil)
        // Shaped like the report, but a mode outside 0...10.
        #expect(mode.value(in: [0x21, 0xFF, 0x00]) == nil)
    }

    @Test func aModeThePanelCannotHoldIsNeverSent() throws {
        let mode = try #require(try deviceMode(KeyGoFixtures.keygoTouchScreen))
        // The KeyGo accepts 0...10.
        #expect(mode.report(11) == nil)
        #expect(mode.report(-1) == nil)
    }

    @Test func aSettingThatCannotHoldMultiInputModeIsIgnored() throws {
        // A 1-bit Device Mode (logical 0...1).
        #expect(try deviceMode("050d090ea101850309521500250175019501b1027507b103c0") == nil)
    }
}
