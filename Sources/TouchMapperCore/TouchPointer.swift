import CoreGraphics

/// One contact of a digitizer report.
public struct Contact: Equatable {
    /// The panel's contact identifier; nil when the panel reports none
    /// (single-touch digitizers and pens).
    public var id: Int?
    public var touching: Bool
    /// False when the panel flags the contact as a palm (Confidence 0).
    public var confident: Bool
    public var x: Double
    public var y: Double

    public init(id: Int?, touching: Bool, confident: Bool = true, x: Double, y: Double) {
        self.id = id
        self.touching = touching
        self.confident = confident
        self.x = x
        self.y = y
    }
}

/// The contents of one digitizer report, uninterpreted.
public struct ContactReport: Equatable {
    /// Every contact slot of the report, in order.
    public var contacts: [Contact]
    /// The Contact Count field, when the panel has one.
    public var count: Int?
    /// The Scan Time field, when the panel has one.
    public var scanTime: Int?

    public init(contacts: [Contact], count: Int?, scanTime: Int? = nil) {
        self.contacts = contacts
        self.count = count
        self.scanTime = scanTime
    }
}

/// Builds complete scans out of reports. A panel either lists every contact
/// in each report (no count field), or states how many contacts the scan has
/// and spreads them over as many reports as it needs, later reports carrying
/// a count of 0 (Windows "hybrid mode"). Nothing is judged on a partial scan.
public struct ScanAssembler {
    private var expected = 0
    private var received: [Contact] = []
    private var lastScanTime: Int?

    public init() {}

    /// Whether a scan has begun but not all its contacts have arrived.
    public var isPending: Bool { received.count < expected }

    /// The complete scan this report finishes, or nil.
    public mutating func add(_ report: ContactReport) -> [Contact]? {
        guard let count = report.count else {
            return report.contacts
        }
        if count > 0 {
            // A new scan; an unfinished one is abandoned unjudged.
            expected = count
            received = []
        } else if !isPending {
            // A zero count with nothing pending is an empty scan (everything
            // lifted), unless it pads the scan that just completed.
            if let time = report.scanTime, time == lastScanTime { return nil }
            lastScanTime = report.scanTime
            return []
        }
        received += report.contacts.prefix(expected - received.count)
        guard !isPending else { return nil }
        lastScanTime = report.scanTime
        let scan = received
        expected = 0
        received = []
        return scan
    }

    public mutating func reset() {
        expected = 0
        received = []
    }
}

/// Turns complete scans into one pointer. A press is granted only on an
/// observed onset: a contact touching now that was not touching in the
/// previous scan, confident, and allowed by `mayPress` (target display
/// present). That contact alone drives the pointer until it lifts, is
/// flagged as a palm, or disappears; the role never passes to another
/// contact. So a palm resting through a touch, or a finger that landed while
/// the display was absent, can never become a press later.
///
/// A second finger is reported alongside (`PointerSample.partner`) under the
/// same rule: it must land during the touch (or with its first finger),
/// confident and with an identity, and it is dropped for good when it lifts.
public struct TouchPointer {
    private var driver: Int??
    private var partner: Int?
    private var previouslyTouching: Set<Int> = []
    private var anyTouchingBefore = false
    private var seeded = false
    private var last: (x: Double, y: Double)?

    /// `panelWasIdle`: the panel sent nothing for a while before this
    /// pointer's first scan, so that scan is a new touch rather than fingers
    /// already resting when the tool started, and may press.
    public init(panelWasIdle: Bool = false) {
        seeded = panelWasIdle
    }

    public var isPressed: Bool { driver != nil }

    /// Whether the last scan had any contact touching. A panel that goes
    /// silent instead of reporting the lift leaves this set until
    /// `releaseAll()`, and a new touch with a remembered identity would not
    /// count as an onset.
    public var isTouching: Bool { anyTouchingBefore }

    /// The pointer state the scan implies, or nil when it changes nothing.
    /// `mayPress` is asked only at an onset.
    public mutating func step(_ scan: [Contact], mayPress: () -> Bool) -> PointerSample? {
        let touching = scan.filter(\.touching)
        let touchingIDs = Set(touching.compactMap(\.id))
        var history = touchingIDs
        defer {
            previouslyTouching = history
            anyTouchingBefore = !touching.isEmpty
            seeded = true
        }

        if let current = driver {
            // Without identities, the driver is whichever contact touches.
            let contact = current.map { id in touching.first { $0.id == id } } ?? touching.first
            if let contact, contact.confident {
                last = (contact.x, contact.y)
                return PointerSample(buttons: 1, x: contact.x, y: contact.y,
                                     partner: follow(partnerAmong: touching, driver: current))
            }
            // Only one sample per scan, so a finger landing in the very scan
            // that ends this touch is left out of the history: its onset is
            // then recognised on the next scan.
            history = previouslyTouching.intersection(touchingIDs)
            return release()
        }

        // The first scan after opening only records who is already touching.
        guard seeded else { return nil }
        let onsets: [Contact]
        if touching.contains(where: { $0.id == nil }) {
            // No identities: a new press needs every contact lifted first.
            onsets = anyTouchingBefore ? [] : Array(touching.prefix(1))
        } else {
            onsets = touching
                .filter { !previouslyTouching.contains($0.id!) }
                .sorted { $0.id! < $1.id! }
        }
        guard let contact = onsets.first(where: \.confident), mayPress() else { return nil }
        driver = .some(contact.id)
        last = (contact.x, contact.y)
        return PointerSample(buttons: 1, x: contact.x, y: contact.y,
                             partner: follow(partnerAmong: touching, driver: contact.id))
    }

    /// The partner's position this scan. A partner that lifts, turns palm or
    /// disappears is not replaced in the same scan, so a finger landing as it
    /// lifts is never taken for it.
    private mutating func follow(partnerAmong touching: [Contact], driver: Int?) -> CGPoint? {
        if let id = partner {
            if let mate = touching.first(where: { $0.id == id }), mate.confident {
                return CGPoint(x: mate.x, y: mate.y)
            }
            partner = nil
            return nil
        }
        guard let driver, let mate = touching.first(where: { contact in
            guard let id = contact.id else { return false }
            return id != driver && !previouslyTouching.contains(id) && contact.confident
        }) else { return nil }
        partner = mate.id
        return CGPoint(x: mate.x, y: mate.y)
    }

    /// Ends everything as if an empty scan arrived: for a lost lift. This
    /// also forgets contacts that may still be resting; a panel that does not
    /// resend stationary contacts can then see one press when it moves. The
    /// alternative, remembering them, would leave a panel that never reports
    /// lifts unable to press again.
    public mutating func releaseAll() -> PointerSample? {
        previouslyTouching = []
        anyTouchingBefore = false
        return driver == nil ? nil : release()
    }

    private mutating func release() -> PointerSample? {
        driver = nil
        partner = nil
        guard let last else { return nil }
        return PointerSample(buttons: 0, x: last.x, y: last.y)
    }
}
