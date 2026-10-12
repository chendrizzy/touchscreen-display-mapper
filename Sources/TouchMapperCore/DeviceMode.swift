/// The Device Mode setting of a Windows-compatible touch panel: a feature on
/// the Digitizers page (0x0D, usage 0x52), in the panel's Device Configuration
/// collection. Such panels start in mouse mode, reporting every touch as one
/// mouse pointer; Windows switches them to multi-input mode, where each finger
/// is reported on its own. macOS never switches them.
public struct DeviceMode: Equatable {
    public static let mouse: Int64 = 0
    public static let multiInput: Int64 = 2

    public let reportID: UInt8
    public let usesReportIDs: Bool
    let field: HIDField
    let bodyLength: Int

    /// The descriptor's first Device Mode feature (some panels declare two and
    /// act only on the first, as Linux found), when it can hold multi-input
    /// mode; nil otherwise.
    public init?(_ descriptor: HIDReportDescriptor) {
        guard let field = descriptor.featureFields.first(where: { $0.usagePage == 0x0D && $0.usage == 0x52 }),
              field.logicalMinimum <= Self.multiInput, Self.multiInput <= field.logicalMaximum,
              let bodyLength = descriptor.featureReportLengths[field.reportID]
        else { return nil }
        reportID = field.reportID
        usesReportIDs = descriptor.usesReportIDs
        self.field = field
        self.bodyLength = bodyLength
    }

    /// Bytes in the feature report as IOKit exchanges it: the body, after the
    /// report-ID byte when the device numbers its reports.
    public var reportLength: Int { bodyLength + (usesReportIDs ? 1 : 0) }

    /// The mode a feature report states; nil when the buffer is not this
    /// report as the descriptor lays it out, or states a mode the panel
    /// cannot hold (which would then be impossible to restore).
    public func value(in report: [UInt8]) -> Int64? {
        guard let value = body(of: report).flatMap(field.value),
              value >= field.logicalMinimum, value <= field.logicalMaximum else { return nil }
        return value
    }

    /// The whole feature report that sets `mode`, built from the descriptor
    /// with every other field zero, as Linux sends it; nil when the
    /// panel cannot hold that mode. Nothing is read first: some panels do not
    /// answer reads of this report.
    public func report(_ mode: Int64) -> [UInt8]? {
        var body = [UInt8](repeating: 0, count: bodyLength)
        guard field.write(mode, into: &body) else { return nil }
        return usesReportIDs ? [reportID] + body : body
    }

    private func body(of report: [UInt8]) -> [UInt8]? {
        guard report.count == reportLength else { return nil }
        guard usesReportIDs else { return report }
        return report.first == reportID ? Array(report.dropFirst()) : nil
    }
}
