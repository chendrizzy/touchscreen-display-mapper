import CoreGraphics

/// One pointer state: buttons held, and an absolute position normalized to
/// 0...1 across the panel (0,0 is the top-left corner).
public struct PointerSample: Equatable {
    /// Bit 0 left (or touching / pen tip), bit 1 right, bit 2 middle.
    public var buttons: UInt8
    public var x: Double
    public var y: Double
    /// Relative wheel motion, when the report carries one.
    public var wheel: Int
    /// A second finger touching with this one (same 0...1 scale), when a
    /// digitizer reports one; see `TouchPointer`.
    public var partner: CGPoint?

    public init(buttons: UInt8, x: Double, y: Double, wheel: Int = 0, partner: CGPoint? = nil) {
        self.buttons = buttons
        self.x = x
        self.y = y
        self.wheel = wheel
        self.partner = partner
    }
}

public enum PointerReport: Equatable {
    /// Mouse emulation: absolute X/Y plus buttons, already one pointer.
    case mouse(PointerSample)
    /// Digitizer: every contact slot; `ScanAssembler` and `TouchPointer`
    /// turn these into one pointer.
    case contacts(ContactReport)
}

/// Reads one kind of absolute pointer report out of a HID interface: either
/// a mouse-emulation report (Generic Desktop absolute X/Y plus buttons, what
/// most touch panels send until a host switches them to multitouch) or a
/// digitizer report (touch screen or pen: per contact a tip switch, an
/// optional contact identifier and confidence, and X/Y).
public struct PointerDecoder: Equatable {
    public enum Source: String, Equatable {
        case mouse
        case digitizer
    }

    struct ButtonField: Equatable {
        var field: HIDField
        var mask: UInt8
    }

    struct ContactSlot: Equatable {
        var tip: HIDField
        var identifier: HIDField?
        var confidence: HIDField?
        var x: HIDField
        var y: HIDField
    }

    public let reportID: UInt8
    public let usesReportIDs: Bool
    public let source: Source
    /// A finger digitizer (Touch Screen application), rather than a pen or a
    /// mouse: only these prove a panel reports its fingers itself.
    public let isTouchScreen: Bool
    let x: HIDField
    let y: HIDField
    // Mouse emulation
    let buttons: [ButtonField]
    let wheel: HIDField?
    // Digitizer
    let slots: [ContactSlot]
    let contactCount: HIDField?
    let scanTime: HIDField?

    /// Application collections that describe a pointer on a screen. Touch
    /// pads (Digitizer 0x05) are left out on purpose: they move the cursor
    /// relatively and must not be pinned to a display.
    private static let pointerApplications: [(page: UInt16, usage: UInt16, source: Source)] = [
        (0x01, 0x01, .mouse),     // Generic Desktop: Pointer
        (0x01, 0x02, .mouse),     // Generic Desktop: Mouse
        (0x0D, 0x01, .digitizer), // Digitizer
        (0x0D, 0x02, .digitizer), // Pen
        (0x0D, 0x03, .digitizer), // Light Pen
        (0x0D, 0x04, .digitizer), // Touch Screen
    ]

    /// One decoder per input report that carries an absolute pointer.
    public static func decoders(for descriptor: HIDReportDescriptor) -> [PointerDecoder] {
        var reportIDs: [UInt8] = []
        for field in descriptor.inputFields where !reportIDs.contains(field.reportID) {
            reportIDs.append(field.reportID)
        }
        return reportIDs.compactMap { id in
            decoder(reportID: id,
                    fields: descriptor.inputFields.filter { $0.reportID == id },
                    usesReportIDs: descriptor.usesReportIDs)
        }
    }

    private static func isAbsolute(_ usage: UInt16) -> (HIDField) -> Bool {
        { $0.usagePage == 0x01 && $0.usage == usage && !$0.isRelative && $0.logicalMaximum > $0.logicalMinimum }
    }

    private static func decoder(reportID: UInt8, fields: [HIDField], usesReportIDs: Bool) -> PointerDecoder? {
        // The first absolute X decides which application this report serves.
        guard let firstX = fields.first(where: isAbsolute(0x30)),
              let application = firstX.collections.first(where: { $0.type == HIDCollection.application }),
              let kind = pointerApplications.first(where: { $0.page == application.usagePage && $0.usage == application.usage })
        else { return nil }
        let inApplication: (HIDField) -> Bool = { $0.collections.contains(application) }
        let isTouchScreen = application.usagePage == 0x0D && application.usage == 0x04
        // A field belongs with an X when it sits in exactly the same
        // collections (for a touch screen, the same finger).
        func sibling(of x: HIDField, page: UInt16, usage: UInt16) -> HIDField? {
            fields.first { $0.usagePage == page && $0.usage == usage && $0.collections == x.collections }
        }

        switch kind.source {
        case .mouse:
            guard let y = fields.first(where: { isAbsolute(0x31)($0) && $0.collections == firstX.collections }) else { return nil }
            let buttons = fields
                .filter { $0.usagePage == 0x09 && (1...3).contains($0.usage) && inApplication($0) }
                .map { ButtonField(field: $0, mask: 1 << UInt8($0.usage - 1)) }
            guard !buttons.isEmpty else { return nil }
            let wheel = fields.first { $0.usagePage == 0x01 && $0.usage == 0x38 && $0.isRelative && inApplication($0) }
            return PointerDecoder(reportID: reportID, usesReportIDs: usesReportIDs, source: .mouse,
                                  isTouchScreen: false, x: firstX, y: y, buttons: buttons, wheel: wheel, slots: [], contactCount: nil, scanTime: nil)

        case .digitizer:
            let slots: [ContactSlot] = fields
                .filter { isAbsolute(0x30)($0) && inApplication($0) }
                .compactMap { x in
                    guard let y = fields.first(where: { isAbsolute(0x31)($0) && $0.collections == x.collections }),
                          let tip = sibling(of: x, page: 0x0D, usage: 0x42)
                    else { return nil }
                    return ContactSlot(tip: tip, identifier: sibling(of: x, page: 0x0D, usage: 0x51),
                                       confidence: sibling(of: x, page: 0x0D, usage: 0x47), x: x, y: y)
                }
            guard let first = slots.first else { return nil }
            let contactCount = fields.first { $0.usagePage == 0x0D && $0.usage == 0x54 && inApplication($0) }
            let scanTime = fields.first { $0.usagePage == 0x0D && $0.usage == 0x56 && inApplication($0) }
            return PointerDecoder(reportID: reportID, usesReportIDs: usesReportIDs, source: .digitizer,
                                  isTouchScreen: isTouchScreen, x: first.x, y: first.y, buttons: [], wheel: nil, slots: slots,
                                  contactCount: contactCount, scanTime: scanTime)
        }
    }

    /// Decodes a raw input report as IOKit delivers it (with its leading
    /// report-ID byte when the device numbers its reports).
    public func decode(_ report: [UInt8]) -> PointerReport? {
        let body: [UInt8]
        if usesReportIDs {
            guard report.first == reportID else { return nil }
            body = Array(report.dropFirst())
        } else {
            body = report
        }

        switch source {
        case .mouse:
            guard let rawX = x.value(in: body), let rawY = y.value(in: body) else { return nil }
            var held: UInt8 = 0
            for button in buttons {
                guard let value = button.field.value(in: body) else { return nil }
                if value != 0 { held |= button.mask }
            }
            let motion = wheel.flatMap { $0.value(in: body) } ?? 0
            return .mouse(PointerSample(buttons: held, x: Self.normalize(rawX, x), y: Self.normalize(rawY, y),
                                        wheel: Int(clamping: motion)))

        case .digitizer:
            var contacts: [Contact] = []
            for slot in slots {
                guard let tip = slot.tip.value(in: body),
                      let rawX = slot.x.value(in: body), let rawY = slot.y.value(in: body)
                else { return nil }
                contacts.append(Contact(
                    id: slot.identifier.flatMap { $0.value(in: body) }.map { Int(clamping: $0) },
                    touching: tip != 0,
                    confident: slot.confidence.flatMap { $0.value(in: body) }.map { $0 != 0 } ?? true,
                    x: Self.normalize(rawX, slot.x), y: Self.normalize(rawY, slot.y)))
            }
            return .contacts(ContactReport(contacts: contacts,
                                           count: contactCount.flatMap { $0.value(in: body) }.map { Int(clamping: $0) },
                                           scanTime: scanTime.flatMap { $0.value(in: body) }.map { Int(clamping: $0) }))
        }
    }

    /// Logical range, for diagnostics: "X 0...16383, Y 0...9599".
    public var rangeDescription: String {
        "X \(x.logicalMinimum)...\(x.logicalMaximum), Y \(y.logicalMinimum)...\(y.logicalMaximum)"
    }

    /// Number of contacts a digitizer report can carry; 1 for a mouse.
    public var contactSlots: Int { source == .mouse ? 1 : slots.count }

    private static func normalize(_ value: Int64, _ field: HIDField) -> Double {
        let span = Double(field.logicalMaximum - field.logicalMinimum)
        return min(max(Double(value - field.logicalMinimum) / span, 0), 1)
    }
}

public enum DisplayMapper {
    /// Maps a normalized panel position onto a display's global bounds,
    /// clamped so the result never leaves the display.
    public static func point(x: Double, y: Double, onto bounds: CGRect) -> CGPoint {
        let nx = min(max(x, 0), 1)
        let ny = min(max(y, 0), 1)
        return CGPoint(x: bounds.minX + nx * (bounds.width - 1),
                       y: bounds.minY + ny * (bounds.height - 1))
    }
}
