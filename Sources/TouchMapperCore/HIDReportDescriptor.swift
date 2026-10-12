/// A collection enclosing a field. `index` tells apart collections that share
/// a usage, such as the ten identical finger collections of a touch screen.
public struct HIDCollection: Equatable {
    public var index: Int
    public var type: UInt8
    public var usagePage: UInt16
    public var usage: UInt16

    public static let physical: UInt8 = 0
    public static let application: UInt8 = 1
    public static let logical: UInt8 = 2
}

/// One value-carrying field of an input or feature report.
public struct HIDField: Equatable {
    /// 0 when the device does not number its reports.
    public var reportID: UInt8
    /// Bit position from the first byte after the report-ID byte.
    public var bitOffset: Int
    public var bitSize: Int
    public var usagePage: UInt16
    public var usage: UInt16
    public var logicalMinimum: Int64
    public var logicalMaximum: Int64
    public var isRelative: Bool
    /// Enclosing collections, outermost first.
    public var collections: [HIDCollection]

    /// Reads this field out of a report body (the report without its ID byte).
    /// Signed when the logical minimum is negative, as the HID spec defines.
    public func value(in body: [UInt8]) -> Int64? {
        guard bitSize > 0, bitSize <= 32, (bitOffset + bitSize + 7) / 8 <= body.count else { return nil }
        var raw: UInt64 = 0
        for bit in 0..<bitSize {
            let position = bitOffset + bit
            if body[position / 8] & (1 << UInt8(position % 8)) != 0 {
                raw |= 1 << UInt64(bit)
            }
        }
        if logicalMinimum < 0, raw & (1 << UInt64(bitSize - 1)) != 0 {
            return Int64(bitPattern: raw | (~UInt64(0) << UInt64(bitSize)))
        }
        return Int64(raw)
    }

    /// Writes `value` into this field of a report body (the report without
    /// its ID byte), leaving every other bit alone. False when the field lies
    /// outside the body or the value outside the field's logical range.
    public func write(_ value: Int64, into body: inout [UInt8]) -> Bool {
        guard bitSize > 0, bitSize <= 32, (bitOffset + bitSize + 7) / 8 <= body.count,
              value >= logicalMinimum, value <= logicalMaximum else { return false }
        let raw = UInt64(bitPattern: value)
        for bit in 0..<bitSize {
            let position = bitOffset + bit
            let mask = UInt8(1) << UInt8(position % 8)
            if raw & (1 << UInt64(bit)) != 0 {
                body[position / 8] |= mask
            } else {
                body[position / 8] &= ~mask
            }
        }
        return true
    }
}

public enum HIDDescriptorError: Error, Equatable {
    case truncated(at: Int)
    case unbalanced(String)
    case outOfRange(String)
}

/// The input and feature sides of a HID report descriptor (HID 1.11, section
/// 6.2.2): every non-constant, variable field with its position, range and
/// collections. Output items, array items and constant padding are not needed
/// to read a pointer or change a setting and are skipped, though padding
/// still advances positions.
public struct HIDReportDescriptor {
    public let inputFields: [HIDField]
    /// Settings the host reads and writes, such as a touch panel's Device Mode.
    public let featureFields: [HIDField]
    /// Bytes in each feature report's body (without the ID byte), by report ID.
    public let featureReportLengths: [UInt8: Int]
    /// Whether reports begin with a report-ID byte.
    public let usesReportIDs: Bool

    private struct Globals {
        var usagePage: UInt32 = 0
        var logicalMinimum: Int64 = 0
        var logicalMaximum: Int64 = 0
        var reportSize = 0
        var reportCount = 0
        var reportID: UInt8 = 0
    }

    /// A usage as declared: `extended` when it carried its own page
    /// (four bytes), so the current usage page never applies to it.
    private enum UsageSpec {
        case single(UInt32, extended: Bool)
        case range(UInt32, UInt32, extended: Bool)
    }

    public init(_ bytes: [UInt8]) throws {
        var globals = Globals()
        var globalStack: [Globals] = []
        var usages: [UsageSpec] = []
        var usageMinimum: (value: UInt32, extended: Bool)?
        var collections: [HIDCollection] = []
        var collectionCount = 0
        // Input and feature reports with the same ID are separate reports.
        var inputOffsets: [UInt8: Int] = [:]
        var featureOffsets: [UInt8: Int] = [:]
        var fields: [HIDField] = []
        var featureFields: [HIDField] = []
        var usesReportIDs = false

        // The declared usages, expanded in order up to `count`; a field past
        // the end of the list takes the last usage, as the spec requires.
        func flattenedUsages(count: Int) -> [UInt32] {
            var flat: [UInt32] = []
            for spec in usages where flat.count < count {
                switch spec {
                case let .single(value, _):
                    flat.append(value)
                case let .range(low, high, _) where low <= high:
                    var value = low
                    while flat.count < count {
                        flat.append(value)
                        if value == high { break }
                        value += 1
                    }
                case .range:
                    break
                }
            }
            return flat
        }

        // HID 1.11 section 6.2.2.8, as Linux applies it
        // (hid_concatenate_last_usage_page): a short usage takes the usage page
        // in effect at its main item, so a Usage Page declared after the
        // usages still applies to them. Walking back from the last usage stops
        // at the first one already on that page, which keeps mixed-page lists
        // such as 05 0D 09 42 05 01 09 30 intact.
        func applyUsagePage() {
            let page = globals.usagePage
            for index in usages.indices.reversed() {
                switch usages[index] {
                case let .single(value, extended: false):
                    if value >> 16 == page { return }
                    usages[index] = .single(page << 16 | value & 0xFFFF, extended: false)
                case let .range(low, high, extended: false):
                    if low >> 16 == page { return }
                    usages[index] = .range(page << 16 | low & 0xFFFF, page << 16 | high & 0xFFFF, extended: false)
                default:
                    continue
                }
            }
        }

        // Local items describe only the next main item.
        func clearLocals() {
            usages.removeAll()
            usageMinimum = nil
        }

        // A one- or two-byte usage takes the current usage page; a four-byte
        // usage carries its own page in the high half.
        func qualified(_ value: UInt32, size: Int) -> UInt32 {
            size == 4 ? value : (globals.usagePage << 16) | (value & 0xFFFF)
        }

        // An Input or Feature main item: one field per report count, each
        // taking the next declared usage, from the next free bit of its report.
        func mainItemFields(flags: UInt32, offsets: inout [UInt8: Int]) throws -> [HIDField] {
            applyUsagePage()
            defer { clearLocals() }
            let isConstant = flags & 0x01 != 0
            let isVariable = flags & 0x02 != 0
            let isRelative = flags & 0x04 != 0
            // Real reports stay far below this; a larger count is a broken
            // or hostile descriptor, not a touchscreen.
            guard globals.reportCount <= 65_535, globals.reportSize <= 1_024 else {
                throw HIDDescriptorError.outOfRange("Report Count \(globals.reportCount) x Report Size \(globals.reportSize)")
            }
            let offset = offsets[globals.reportID, default: 0]
            offsets[globals.reportID] = offset + globals.reportCount * globals.reportSize
            guard !isConstant, isVariable else { return [] }
            let flat = flattenedUsages(count: globals.reportCount)
            var found: [HIDField] = []
            for index in 0..<globals.reportCount {
                guard let full = index < flat.count ? flat[index] : flat.last else { break }
                found.append(HIDField(
                    reportID: globals.reportID, bitOffset: offset + index * globals.reportSize, bitSize: globals.reportSize,
                    usagePage: UInt16(full >> 16), usage: UInt16(full & 0xFFFF),
                    logicalMinimum: globals.logicalMinimum, logicalMaximum: globals.logicalMaximum,
                    isRelative: isRelative, collections: collections))
            }
            return found
        }

        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            if prefix == 0xFE {
                // Long item: size byte, tag byte, data. None are defined for HID.
                guard i + 2 < bytes.count else { throw HIDDescriptorError.truncated(at: i) }
                i += 3 + Int(bytes[i + 1])
                continue
            }
            let size = prefix & 0x03 == 3 ? 4 : Int(prefix & 0x03)
            let type = (prefix >> 2) & 0x03
            let tag = prefix >> 4
            guard i + size < bytes.count else { throw HIDDescriptorError.truncated(at: i) }
            let data = bytes[(i + 1)..<(i + 1 + size)]
            i += 1 + size

            var unsigned: UInt32 = 0
            for (shift, byte) in data.enumerated() {
                unsigned |= UInt32(byte) << UInt32(8 * shift)
            }
            var signed = Int64(unsigned)
            if size > 0, size < 4, unsigned & (1 << UInt32(8 * size - 1)) != 0 {
                signed -= Int64(1) << Int64(8 * size)
            } else if size == 4 {
                signed = Int64(Int32(bitPattern: unsigned))
            }

            switch (type, tag) {
            // Main items
            case (0, 0x8): // Input
                fields += try mainItemFields(flags: unsigned, offsets: &inputOffsets)
            case (0, 0xB): // Feature
                featureFields += try mainItemFields(flags: unsigned, offsets: &featureOffsets)
            case (0, 0xA): // Collection
                applyUsagePage()
                let full = flattenedUsages(count: 1).first ?? 0
                collections.append(HIDCollection(index: collectionCount, type: UInt8(unsigned & 0xFF),
                                                 usagePage: UInt16(full >> 16), usage: UInt16(full & 0xFFFF)))
                collectionCount += 1
                clearLocals()
            case (0, 0xC): // End Collection
                guard !collections.isEmpty else { throw HIDDescriptorError.unbalanced("End Collection without Collection") }
                collections.removeLast()
                clearLocals()
            case (0, _): // Output
                clearLocals()

            // Global items
            case (1, 0x0): globals.usagePage = unsigned & 0xFFFF
            case (1, 0x1): globals.logicalMinimum = signed
            // Linux's rule: the maximum is signed only when the minimum is.
            case (1, 0x2): globals.logicalMaximum = globals.logicalMinimum < 0 ? signed : Int64(unsigned)
            case (1, 0x7): globals.reportSize = Int(unsigned)
            case (1, 0x8):
                globals.reportID = UInt8(truncatingIfNeeded: unsigned)
                usesReportIDs = true
            case (1, 0x9): globals.reportCount = Int(unsigned)
            case (1, 0xA): globalStack.append(globals)
            case (1, 0xB):
                guard let restored = globalStack.popLast() else { throw HIDDescriptorError.unbalanced("Pop without Push") }
                globals = restored

            // Local items
            case (2, 0x0): usages.append(.single(qualified(unsigned, size: size), extended: size == 4))
            case (2, 0x1): usageMinimum = (qualified(unsigned, size: size), size == 4)
            case (2, 0x2):
                if let low = usageMinimum {
                    usages.append(.range(low.value, qualified(unsigned, size: size), extended: low.extended))
                    usageMinimum = nil
                }

            default:
                break
            }
        }

        inputFields = fields
        self.featureFields = featureFields
        featureReportLengths = featureOffsets.mapValues { ($0 + 7) / 8 }
        self.usesReportIDs = usesReportIDs
    }
}
