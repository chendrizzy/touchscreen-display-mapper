import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
import TouchMapperCore

// touchscreen-display-mapper: makes a USB touchscreen click on its own display.
//
// macOS has no way to tie a touch panel to a display: it scales the panel's
// absolute coordinates onto whichever display holds the cursor. This agent
// seizes the panel so macOS stops acting on it, decodes its reports from the
// panel's own HID report descriptor, and posts mouse events inside the chosen
// display's bounds instead.
//
// Failure policy: the agent is either fully working or it exits non-zero.
// launchd's KeepAlive is the only retry loop; nothing here retries in-process.

// MARK: - Command line

struct DeviceID: Equatable, CustomStringConvertible {
    var vendor: Int
    var product: Int

    /// "27c0:0859" (hexadecimal, as `list-devices` prints it).
    init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        func hex(_ part: Substring) -> Int? {
            let digits = part.hasPrefix("0x") ? part.dropFirst(2) : part
            guard (1...4).contains(digits.count), let value = Int(digits, radix: 16) else { return nil }
            return value
        }
        guard parts.count == 2, let vendor = hex(parts[0]), let product = hex(parts[1]) else { return nil }
        self.vendor = vendor
        self.product = product
    }

    init(vendor: Int, product: Int) {
        self.vendor = vendor
        self.product = product
    }

    var description: String { String(format: "%04x:%04x", vendor, product) }
}

struct DisplaySpec: Equatable, CustomStringConvertible {
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32?

    /// "19083:13107" or "19083:13107:12345" (decimal, as `list-displays` prints it).
    init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { UInt32($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        vendor = parts[0]!
        model = parts[1]!
        serial = parts.count == 3 ? parts[2] : nil
    }

    func matches(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == vendor && CGDisplayModelNumber(id) == model
            && (serial == nil || CGDisplaySerialNumber(id) == serial)
    }

    var description: String { serial.map { "\(vendor):\(model):\($0)" } ?? "\(vendor):\(model)" }
}

struct RunOptions {
    var device: DeviceID
    var display: DisplaySpec
    var observe = false
    var trace = 40
    /// nil disables the lift timeout.
    var liftTimeout: TimeInterval? = 0.5
    var multitouch = false
    var gestures = false
    var pinch = false
}

enum Command {
    case run(RunOptions)
    case listDevices
    case listDisplays
}

let usage = """
usage:
  touchscreen-display-mapper list-devices
  touchscreen-display-mapper list-displays
  touchscreen-display-mapper run --device VID:PID --display VENDOR:MODEL[:SERIAL] [options]

Seizes a USB touchscreen and replays its touches as mouse events on the display
you name, instead of on whichever display holds the cursor.

  list-devices         absolute-pointer HID devices (touchscreens, pen displays)
                       and the --device value for each
  list-displays        online displays and the --display value for each

run options:
  --device VID:PID     the touch panel, hexadecimal, from list-devices
  --display V:M[:S]    the display it sits on, from list-displays
  --observe            open the panel shared and post nothing; log each touch
                       and where it would land
  --trace N            log the first N reports (default 40)
  --lift-timeout MS    release a held touch after MS milliseconds without a
                       report (default 500; 0 disables). Panels resend while a
                       finger is down; raise this, or use 0, if long presses
                       get cut short.
  --multitouch         switch the panel to multi-input mode, which reports
                       each finger (Windows-style panels start as a one-finger
                       mouse). Put back when the agent stops.
  --gestures           phone-style touch: a tap clicks, a finger that moves
                       scrolls what is under it, and a finger that rests half
                       a second presses and drags; two fingers scroll on
                       panels that report each finger
  --pinch              with --gestures, zoom: double-tap, then drag down to
                       zoom in or up to zoom out (two fingers pinch on panels
                       that report each finger). Uses undocumented macOS
                       gesture events.
"""

func parseCommand(_ arguments: [String]) -> Command {
    var args = arguments.dropFirst().makeIterator()
    guard let verb = args.next() else { fail(usage) }
    switch verb {
    case "list-devices": return .listDevices
    case "list-displays": return .listDisplays
    case "-h", "--help", "help": print(usage); exit(0)
    case "run": break
    default: fail("unknown command: \(verb)\n\n\(usage)")
    }

    var device: DeviceID?
    var display: DisplaySpec?
    var observe = false
    var trace = 40
    var liftTimeout: TimeInterval? = 0.5
    var multitouch = false
    var gestures = false
    var pinch = false
    func value(after flag: String) -> String {
        guard let raw = args.next() else { fail("\(flag) needs a value") }
        return raw
    }
    func count(after flag: String) -> Int {
        guard let number = Int(value(after: flag)), number >= 0 else { fail("\(flag) needs a non-negative whole number") }
        return number
    }
    while let arg = args.next() {
        switch arg {
        case "--device":
            guard let parsed = DeviceID(value(after: arg)) else { fail("--device takes VID:PID in hex, e.g. 27c0:0859") }
            device = parsed
        case "--display":
            guard let parsed = DisplaySpec(value(after: arg)) else { fail("--display takes VENDOR:MODEL[:SERIAL] in decimal, e.g. 19083:13107") }
            display = parsed
        case "--observe": observe = true
        case "--trace": trace = count(after: arg)
        case "--lift-timeout":
            let ms = count(after: arg)
            liftTimeout = ms == 0 ? nil : TimeInterval(ms) / 1000
        case "--multitouch": multitouch = true
        case "--gestures": gestures = true
        case "--pinch": pinch = true
        default: fail("unknown argument: \(arg)\n\n\(usage)")
        }
    }
    guard let device else { fail("run needs --device (see list-devices)") }
    guard let display else { fail("run needs --display (see list-displays)") }
    guard !pinch || gestures else { fail("--pinch needs --gestures") }
    return .run(RunOptions(device: device, display: display, observe: observe, trace: trace,
                           liftTimeout: liftTimeout, multitouch: multitouch, gestures: gestures, pinch: pinch))
}

// MARK: - Logging

let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

func log(_ message: String) {
    print("\(timestampFormatter.string(from: Date())) \(message)")
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("touchscreen-display-mapper: \(message)\n".utf8))
    exit(64)
}

/// Exit code that tells launchd (KeepAlive SuccessfulExit=false) to try again.
let exitRetry: Int32 = 75

func describe(_ result: IOReturn) -> String {
    let code = "0x" + String(UInt32(bitPattern: result), radix: 16)
    switch result {
    case kIOReturnNotPermitted: return "\(code) not permitted (Input Monitoring?)"
    case kIOReturnExclusiveAccess: return "\(code) another process already seized it"
    case kIOReturnNotPrivileged: return "\(code) not privileged"
    default: return code
    }
}

// MARK: - HID helpers

func intProperty(_ device: IOHIDDevice, _ key: String) -> Int {
    (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
}

func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
    IOHIDDeviceGetProperty(device, key as CFString) as? String
}

/// An interface's own report descriptor, parsed; nil when it has none.
func reportDescriptor(_ device: IOHIDDevice) -> Result<HIDReportDescriptor?, Error> {
    guard let data = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data else {
        return .success(nil)
    }
    return Result { try HIDReportDescriptor([UInt8](data)) }
}

/// The pointer decoders an interface's own report descriptor describes.
func pointerDecoders(_ device: IOHIDDevice) -> Result<[PointerDecoder], Error> {
    reportDescriptor(device).map { $0.map(PointerDecoder.decoders(for:)) ?? [] }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

func interfaceLabel(_ device: IOHIDDevice) -> String {
    "page \(intProperty(device, kIOHIDPrimaryUsagePageKey)) usage \(intProperty(device, kIOHIDPrimaryUsageKey))"
}

func decoderSummary(_ decoder: PointerDecoder) -> String {
    let kind = decoder.source == .mouse ? "mouse emulation" : "digitizer, \(decoder.contactSlots) contact slot\(decoder.contactSlots == 1 ? "" : "s")"
    return "report \(decoder.reportID), \(kind), \(decoder.rangeDescription)"
}

// MARK: - list-devices / list-displays

func listDevices() {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, nil)
    let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []

    var lines: [String: [String]] = [:]
    var names: [String: String] = [:]
    for device in devices {
        guard case let .success(decoders) = pointerDecoders(device), !decoders.isEmpty else { continue }
        let id = DeviceID(vendor: intProperty(device, kIOHIDVendorIDKey), product: intProperty(device, kIOHIDProductIDKey))
        let product = stringProperty(device, kIOHIDProductKey) ?? "unnamed"
        let maker = stringProperty(device, kIOHIDManufacturerKey).map { " (\($0))" } ?? ""
        names[id.description] = product + maker
        for decoder in decoders {
            lines[id.description, default: []].append("\(interfaceLabel(device)): \(decoderSummary(decoder))")
        }
    }

    guard !lines.isEmpty else {
        print("No absolute-pointer HID devices found. Is the touchscreen's USB cable connected?")
        print("(Regular mice and trackpads move the cursor relatively and are not listed.)")
        return
    }
    print("Absolute-pointer HID devices (touchscreens, pen displays):\n")
    for id in lines.keys.sorted() {
        print("  \(id)  \(names[id] ?? "")")
        for line in lines[id]!.sorted() {
            print("      \(line)")
        }
    }
    print("\nPass the first column as --device.")
}

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}

func listDisplays() {
    var screenNames: [CGDirectDisplayID: String] = [:]
    for screen in NSScreen.screens {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            screenNames[number.uint32Value] = screen.localizedName
        }
    }
    let ids = onlineDisplays()
    print("Online displays:\n")
    for id in ids {
        let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id)
        let twins = ids.filter { CGDisplayVendorNumber($0) == vendor && CGDisplayModelNumber($0) == model }
        let serial = CGDisplaySerialNumber(id)
        let spec = twins.count > 1 ? "\(vendor):\(model):\(serial)" : "\(vendor):\(model)"
        let identical = twins.filter { CGDisplaySerialNumber($0) == serial }.count > 1
            ? "  (cannot be targeted: an identical display reports the same serial)" : ""
        let bounds = CGDisplayBounds(id)
        let main = CGDisplayIsMain(id) != 0 ? ", main" : ""
        let name = screenNames[id].map { "\"\($0)\"" } ?? "(asleep or mirrored)"
        print("  \(spec.padding(toLength: 22, withPad: " ", startingAt: 0)) \(name)  \(Int(bounds.width))x\(Int(bounds.height)) at (\(Int(bounds.minX)), \(Int(bounds.minY)))\(main)\(identical)")
    }
    print("\nPass the first column as --display.")
}

// MARK: - Permissions

/// Input Monitoring to read the panel; Accessibility (post events) to click.
/// A grant made after asking may not be visible to the asking process, so the
/// agent exits and lets launchd relaunch it to read the new state.
func permissionsReady(observe: Bool) -> Bool {
    var ready = true
    if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
        log("Input Monitoring not granted. Requesting; enable touchscreen-display-mapper in System Settings > Privacy & Security > Input Monitoring.")
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        ready = false
    }
    if !observe && !CGPreflightPostEventAccess() {
        log("Accessibility not granted. Requesting; enable touchscreen-display-mapper in System Settings > Privacy & Security > Accessibility.")
        _ = CGRequestPostEventAccess()
        ready = false
    }
    return ready
}

// MARK: - Target display

/// Finds the target display fresh for every touch: display IDs can change
/// when a display is replugged. Online rather than active displays, so a touch
/// on a sleeping display still lands and wakes it.
final class TargetDisplay {
    private let spec: DisplaySpec
    private var lastLogged: CGDirectDisplayID?
    private var reported: String?

    init(_ spec: DisplaySpec) {
        self.spec = spec
    }

    func currentBounds() -> CGRect? {
        let matches = onlineDisplays().filter(spec.matches)
        guard matches.count == 1, let id = matches.first else {
            let problem = matches.isEmpty
                ? "display \(spec) is not online; dropping touches until it is."
                : spec.serial == nil
                    ? "\(matches.count) displays match \(spec); add the serial (see list-displays). Dropping touches."
                    : "\(matches.count) displays match \(spec), serial included, so they cannot be told apart. Dropping touches."
            if problem != reported {
                reported = problem
                lastLogged = nil
                log(problem)
            }
            return nil
        }
        reported = nil
        let bounds = CGDisplayBounds(id)
        if id != lastLogged {
            lastLogged = id
            log("target display: id \(id), bounds \(bounds)")
        }
        return bounds
    }
}

// MARK: - Event posting

final class EventPoster {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var pressClicks: [MouseButton: Int] = [:]
    private var lastPosted: CGPoint?
    /// Sub-pixel scroll left over from earlier steps of a pan.
    private var panRemainder = CGPoint.zero

    func post(_ action: PointerAction) {
        switch action {
        case let .move(point):
            mouse(.mouseMoved, at: point, button: .left, clickState: nil)
        case let .down(button, point, clicks):
            pressClicks[button] = clicks
            mouse(Self.types(button).down, at: point, button: button, clickState: clicks)
        case let .drag(button, point):
            mouse(Self.types(button).drag, at: point, button: button, clickState: pressClicks[button])
        case let .up(button, point, clicks):
            mouse(Self.types(button).up, at: point, button: button, clickState: clicks)
        case let .scroll(lines):
            CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
                    wheel1: Int32(clamping: lines), wheel2: 0, wheel3: 0)?
                .post(tap: .cghidEventTap)
        case let .pan(dx, dy, point, phase):
            pan(dx: dx, dy: dy, at: point, phase)
        case let .magnify(delta, point, phase):
            magnify(delta, at: point, phase)
        }
    }

    /// A scroll in pixels, marked as a continuous (trackpad-like) gesture.
    /// A positive wheel value moves content down, as a finger moving down
    /// does on a touchscreen.
    private func pan(dx: CGFloat, dy: CGFloat, at point: CGPoint, _ phase: GesturePhase) {
        if phase == .began { panRemainder = .zero }
        let wanted = CGPoint(x: dx + panRemainder.x, y: dy + panRemainder.y)
        let whole = CGPoint(x: wanted.x.rounded(), y: wanted.y.rounded())
        panRemainder = CGPoint(x: wanted.x - whole.x, y: wanted.y - whole.y)
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(whole.y), wheel2: Int32(whole.x), wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(Self.scrollPhase(phase).rawValue))
        // A scroll has no position of its own and goes to whatever is under
        // the cursor; the location aims it at the finger.
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    /// The gesture event a trackpad pinch produces (NSEvent type .magnify).
    /// No public API creates one: the event type and fields below are the
    /// undocumented encoding the window server reads, taken from HIDTouch
    /// (github.com/koshi545/HIDTouch, CGEventInjector.swift, MIT License,
    /// Copyright (c) 2026 koshi545). A macOS update can change them, and an
    /// event it no longer understands is dropped without any error.
    private func magnify(_ delta: CGFloat, at point: CGPoint, _ phase: GesturePhase) {
        guard let event = CGEvent(source: source),
              let gesture = CGEventType(rawValue: 29),          // NSEventTypeGesture
              let kind = CGEventField(rawValue: 110),           // which gesture
              let zoom = CGEventField(rawValue: 113),           // fractional change in scale
              let gesturePhase = CGEventField(rawValue: 132)    // a CGGesturePhase
        else { return }
        event.type = gesture
        event.setIntegerValueField(kind, value: 8)              // kIOHIDEventTypeZoom
        event.setIntegerValueField(gesturePhase, value: Int64(Self.gesturePhase(phase).rawValue))
        event.setDoubleValueField(zoom, value: Double(delta))
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    private static func scrollPhase(_ phase: GesturePhase) -> CGScrollPhase {
        switch phase {
        case .began: return .began
        case .changed: return .changed
        case .ended: return .ended
        }
    }

    private static func gesturePhase(_ phase: GesturePhase) -> CGGesturePhase {
        switch phase {
        case .began: return .began
        case .changed: return .changed
        case .ended: return .ended
        }
    }

    private func mouse(_ type: CGEventType, at point: CGPoint, button: MouseButton, clickState: Int?) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: Self.cgButton(button)) else { return }
        if let clickState {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        // Relative motion for apps that track it. A touch always opens with a
        // move, measured from the live cursor (another device may have moved
        // it); every later step is measured from what was posted last, which
        // the live cursor may not reflect yet.
        let origin = type == .mouseMoved ? CGEvent(source: nil)?.location : lastPosted
        if let origin {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - origin.x).rounded()))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - origin.y).rounded()))
        }
        lastPosted = point
        event.post(tap: .cghidEventTap)
    }

    private static func cgButton(_ button: MouseButton) -> CGMouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    private static func types(_ button: MouseButton) -> (down: CGEventType, drag: CGEventType, up: CGEventType) {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseDragged, .leftMouseUp)
        case .right: return (.rightMouseDown, .rightMouseDragged, .rightMouseUp)
        case .middle: return (.otherMouseDown, .otherMouseDragged, .otherMouseUp)
        }
    }
}

// MARK: - Panel

final class TouchBridge {
    /// One report stream: a decoder on an opened interface.
    struct SourceKey: Hashable {
        var interface: ObjectIdentifier
        var reportID: UInt8
    }

    /// One opened interface of the panel: its decoders, the per-stream state
    /// they feed, and the buffer IOKit fills per report.
    final class OpenInterface {
        unowned let bridge: TouchBridge
        let device: IOHIDDevice
        let label: String
        let decoders: [PointerDecoder]
        let buffer: UnsafeMutablePointer<UInt8>
        let capacity: Int
        var ignoredReportIDs: Set<UInt32> = []
        /// Per digitizer report: scan assembly, and the touch it drives.
        var assemblers: [UInt8: ScanAssembler] = [:]
        var pointers: [UInt8: TouchPointer] = [:]
        /// Per mouse-emulation report: the buttons it last reported.
        var mouseButtons: [UInt8: UInt8] = [:]
        /// The Device Mode to put back on exit, after --multitouch changed it.
        var modeToRestore: (setting: DeviceMode, value: Int64)?
        let openedAt = ProcessInfo.processInfo.systemUptime

        init(bridge: TouchBridge, device: IOHIDDevice, label: String, decoders: [PointerDecoder], capacity: Int) {
            self.bridge = bridge
            self.device = device
            self.label = label
            self.decoders = decoders
            self.capacity = capacity
            buffer = .allocate(capacity: capacity)
            buffer.initialize(repeating: 0, count: capacity)
        }

        deinit { buffer.deallocate() }

        /// Anything touching, pressed or half-reported that a lost lift
        /// could leave stuck.
        var isBusy: Bool {
            mouseButtons.values.contains { $0 != 0 }
                || assemblers.values.contains(where: \.isPending)
                || pointers.values.contains { $0.isPressed || $0.isTouching }
        }
    }

    private let options: RunOptions
    private let manager: IOHIDManager
    private let display: TargetDisplay
    private let poster = EventPoster()
    private var touch: TouchGestures
    private var interfaces: [OpenInterface] = []
    private var traced = 0

    /// Where the touch in progress is placed, fixed when it starts.
    private var touchBounds: CGRect?
    /// The stream driving the touch in progress; no other stream can move or
    /// release it.
    private var activeSource: SourceKey?
    /// Once a touch-screen digitizer stream has reported a touch, the panel's
    /// mouse emulation is a compatibility copy of the same fingers and is
    /// ignored (until the panel is unplugged). A pen stream proves nothing:
    /// pens report as pens in every mode, while fingers may still arrive only
    /// through the mouse emulation.
    private var digitizerSeen = false
    /// --multitouch sent multi-input mode to an interface still attached.
    private var multiInputSent: Bool { interfaces.contains { $0.modeToRestore != nil } }
    private var warnedMouseAfterSwitch = false
    private var liftTimer: Timer?
    private var holdTimer: Timer?
    /// When the lift timer last restarted: the last report that proves the
    /// touch in progress (or, between touches, the panel) is alive.
    private var lastEvidence: TimeInterval = 0

    init(options: RunOptions) {
        self.options = options
        touch = TouchGestures(doubleClickInterval: NSEvent.doubleClickInterval,
                              gestures: options.gestures, pinch: options.pinch)
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        display = TargetDisplay(options.display)
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let matching: [String: Any] = [kIOHIDVendorIDKey: options.device.vendor, kIOHIDProductIDKey: options.device.product]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<TouchBridge>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<TouchBridge>.fromOpaque(context).takeUnretainedValue().detach(device)
        }, context)
        // Never IOHIDManagerOpen: it opens every matched device shared through
        // this client, and a later seize on the same client silently does not
        // take, leaving macOS still driving the cursor. Each interface is opened
        // on its own in attach(). Scheduling alone delivers the match callbacks.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        log("waiting for touch panel \(options.device); target display \(options.display)")
    }

    /// Ends everything as if every finger had lifted: posts the release for a
    /// held press and clears the digitizer streams. Mouse-emulation streams
    /// keep their button level: mouse reports always carry the button-up, and
    /// a press still held after a stall must not count as a new press.
    func releaseHeld(reason: String) {
        liftTimer?.invalidate()
        liftTimer = nil
        holdTimer?.invalidate()
        holdTimer = nil
        activeSource = nil
        touchBounds = nil
        for interface in interfaces {
            for id in interface.pointers.keys { _ = interface.pointers[id]?.releaseAll() }
            for id in interface.assemblers.keys { interface.assemblers[id]?.reset() }
        }
        let actions = touch.releaseAll()
        guard !actions.isEmpty else { return }
        log("ending the touch in progress: \(reason)")
        if !options.observe {
            actions.forEach(poster.post)
        }
    }

    private func attach(_ device: IOHIDDevice) {
        guard !interfaces.contains(where: { CFEqual($0.device, device) }) else { return }
        let label = interfaceLabel(device)
        let descriptor: HIDReportDescriptor?
        switch reportDescriptor(device) {
        case let .success(parsed):
            descriptor = parsed
        case let .failure(error):
            log("leaving \(label) alone: its report descriptor could not be read (\(error))")
            return
        }
        let decoders = descriptor.map(PointerDecoder.decoders(for:)) ?? []
        // Only interfaces that carry an absolute pointer are taken over; any
        // other interface of the device (keys, vendor channels) is left alone.
        guard !decoders.isEmpty else {
            log("leaving \(label) alone: no absolute pointer in its report descriptor")
            return
        }

        let mode = options.observe ? kIOHIDOptionsTypeNone : kIOHIDOptionsTypeSeizeDevice
        let result = IOHIDDeviceOpen(device, IOOptionBits(mode))
        guard result == kIOReturnSuccess else {
            // A half-owned panel would click twice or not at all. Exiting
            // releases whatever is already seized and hands the retry to launchd.
            log("could not open \(label): \(describe(result)); exiting so launchd retries")
            exitForRetry()
        }

        let capacity = max(intProperty(device, kIOHIDMaxInputReportSizeKey), 64)
        let interface = OpenInterface(bridge: self, device: device, label: label, decoders: decoders, capacity: capacity)
        interfaces.append(interface)
        IOHIDDeviceRegisterInputReportCallback(device, interface.buffer, capacity, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            let interface = Unmanaged<OpenInterface>.fromOpaque(context).takeUnretainedValue()
            interface.bridge.handle(Array(UnsafeBufferPointer(start: report, count: length)), reportID: reportID, from: interface)
        }, Unmanaged.passUnretained(interface).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        log("opened \(label) \(options.observe ? "shared (observe)" : "seized"): " + decoders.map(decoderSummary).joined(separator: "; "))
        if options.multitouch, decoders.contains(where: { $0.source == .digitizer }) {
            enableMultiInput(on: interface, setting: descriptor.flatMap(DeviceMode.init))
        }
    }

    // MARK: Device Mode

    /// What reading a panel's Device Mode gave.
    enum ModeReading {
        case value(Int64)
        /// The panel did not answer with the report its descriptor declares.
        case unreadable(String)
    }

    /// Switches a digitizer interface to multi-input mode. The report is
    /// written without reading it first, because some panels (the KeyGo among
    /// them) answer a read with garbage. A read is only advice; the proof is
    /// digitizer touches arriving.
    private func enableMultiInput(on interface: OpenInterface, setting: DeviceMode?) {
        guard let setting else {
            log("\(interface.label) has no Device Mode setting; --multitouch changes nothing on it")
            return
        }
        let before = readMode(setting, of: interface)
        guard writeMode(DeviceMode.multiInput, setting, of: interface) else {
            log("\(interface.label) stays as it was; touches keep arriving one finger at a time")
            return
        }
        // Mouse mode is what these panels start in, so it is what a stop puts
        // back unless the panel said otherwise. A panel already in multi-input
        // mode was most likely left so by a run that could not restore it.
        switch before {
        case let .value(value) where value != DeviceMode.multiInput:
            interface.modeToRestore = (setting, value)
        case .value:
            interface.modeToRestore = (setting, DeviceMode.mouse)
            log("\(interface.label) was already in Device Mode \(DeviceMode.multiInput); mouse mode is put back on stop")
        case let .unreadable(reason):
            interface.modeToRestore = (setting, DeviceMode.mouse)
            log("\(interface.label) cannot be read back (\(reason)); mouse mode is put back on stop")
        }
        if case let .value(after) = readMode(setting, of: interface) {
            log(after == DeviceMode.multiInput
                ? "Device Mode now \(after) (multi-input) on \(interface.label); digitizer touches should follow"
                : "\(interface.label) took the write but reads back Device Mode \(after); it may have ignored it")
        } else {
            log("sent Device Mode \(DeviceMode.multiInput) (multi-input) to \(interface.label); digitizer touches arriving will confirm it")
        }
    }

    /// Puts every panel --multitouch switched back in the mode it was in.
    func restoreModes() {
        for interface in interfaces {
            guard let (setting, value) = interface.modeToRestore else { continue }
            interface.modeToRestore = nil
            guard writeMode(value, setting, of: interface) else { continue }
            switch readMode(setting, of: interface) {
            case let .value(now) where now == value:
                log("restored Device Mode \(value) on \(interface.label)")
            case let .value(now):
                log("sent Device Mode \(value) to \(interface.label) to restore it, but it reads back \(now)")
            case .unreadable:
                log("sent Device Mode \(value) to \(interface.label) to restore it; it cannot be read back")
            }
        }
    }

    /// Writes the Device Mode report; false (logged) when it did not go out.
    private func writeMode(_ value: Int64, _ setting: DeviceMode, of interface: OpenInterface) -> Bool {
        guard let report = setting.report(value) else {
            log("Device Mode \(value) is outside what \(interface.label) accepts")
            return false
        }
        let result = IOHIDDeviceSetReport(interface.device, kIOHIDReportTypeFeature, CFIndex(setting.reportID), report, report.count)
        guard result == kIOReturnSuccess else {
            log("could not set Device Mode \(value) on \(interface.label): \(describe(result))")
            return false
        }
        return true
    }

    private func readMode(_ setting: DeviceMode, of interface: OpenInterface) -> ModeReading {
        var buffer = [UInt8](repeating: 0, count: setting.reportLength)
        var length = CFIndex(buffer.count)
        let result = IOHIDDeviceGetReport(interface.device, kIOHIDReportTypeFeature, CFIndex(setting.reportID), &buffer, &length)
        guard result == kIOReturnSuccess else { return .unreadable("read failed: \(describe(result))") }
        let report = Array(buffer.prefix(max(0, min(length, buffer.count))))
        guard let value = setting.value(in: report) else {
            return .unreadable("it answered [\(hex(report))], not feature report \(setting.reportID)")
        }
        return .value(value)
    }

    /// Exits for launchd to retry, handing every panel back as it was found.
    private func exitForRetry() -> Never {
        restoreModes()
        exit(exitRetry)
    }

    private func detach(_ device: IOHIDDevice) {
        guard let index = interfaces.firstIndex(where: { CFEqual($0.device, device) }) else { return }
        let interface = interfaces.remove(at: index)
        // Unschedule and close while `interface` still owns the report buffer,
        // so IOKit can no longer write into it once it is freed.
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        log("touch panel removed: \(interface.label)")
        if interfaces.isEmpty {
            digitizerSeen = false
            warnedMouseAfterSwitch = false
        }
        releaseHeld(reason: "touch panel removed")
    }

    fileprivate func handle(_ bytes: [UInt8], reportID: UInt32, from interface: OpenInterface) {
        guard let (decoder, report) = interface.decoders.lazy
            .compactMap({ decoder in decoder.decode(bytes).map { (decoder, $0) } }).first
        else {
            if interface.ignoredReportIDs.insert(reportID).inserted {
                log("ignoring report id \(reportID) (\(bytes.count) bytes) on \(interface.label): not a pointer report")
            }
            return
        }
        let key = SourceKey(interface: ObjectIdentifier(interface), reportID: decoder.reportID)
        // One clock reading per report, so a timer due at the same moment as
        // the silence limit compares equal rather than by microseconds.
        let now = ProcessInfo.processInfo.systemUptime
        defer { armLiftTimer(after: key, at: now) }

        switch report {
        case var .mouse(sample):
            // With gestures only the touch (button 0) counts. Reducing the
            // report here makes starting, hovering and ownership agree with
            // what the gestures read, so a held pen button cannot block a touch.
            if options.gestures { sample.buttons &= 1 }
            if multiInputSent, !digitizerSeen, sample.buttons != 0, !warnedMouseAfterSwitch {
                warnedMouseAfterSwitch = true
                log("a touch arrived as mouse emulation after multi-input mode was sent; "
                    + "if no digitizer touches follow, the panel ignored the switch")
            }
            // A touch this stream already owns is always finished here.
            guard !digitizerSeen || activeSource == key else { return }
            let before = interface.mouseButtons[decoder.reportID] ?? 0
            interface.mouseButtons[decoder.reportID] = sample.buttons
            if touch.isActive {
                guard activeSource == key else { return }
            } else if sample.buttons != 0 {
                // Only a press that begins in this report may start a touch.
                // A press already held (one that began while the display was
                // missing, or belongs to another stream) never can.
                guard before == 0, beginTouch(from: key) else { return }
            } else {
                // Hovering, which only pens do. A buttons-up report right
                // after a press is a lift (often with a meaningless position),
                // not hover.
                guard before == 0, let bounds = display.currentBounds() else { return }
                touchBounds = bounds
            }
            drive(sample, from: key, bytes: bytes, time: now)

        case let .contacts(contacts):
            guard let scan = interface.assemblers[decoder.reportID, default: ScanAssembler()].add(contacts) else { return }
            if !digitizerSeen, decoder.isTouchScreen, scan.contains(where: \.touching) {
                digitizerSeen = true
                log("digitizer touches are arriving; this panel's mouse-emulation reports are ignored from now on")
            }
            if interface.pointers[decoder.reportID] == nil {
                // An idle digitizer sends nothing, so a first scan arriving
                // well after the interface opened is a new touch, not a
                // finger that was already resting at startup.
                let idle = ProcessInfo.processInfo.systemUptime - interface.openedAt > 0.5
                interface.pointers[decoder.reportID] = TouchPointer(panelWasIdle: idle)
            }
            let owns = !touch.isActive || activeSource == key
            // Every scan updates this stream's history, owned or not, so an
            // onset it misses now can never surface later as a phantom press.
            let sample = interface.pointers[decoder.reportID, default: TouchPointer()].step(scan) {
                owns && self.beginTouch(from: key)
            }
            guard let sample, owns else { return }
            drive(sample, from: key, bytes: bytes, time: now)
        }
    }

    /// Starts a touch from `key` when it may: the target display is present
    /// (its placement is fixed for the whole touch) and the agent can still
    /// click.
    private func beginTouch(from key: SourceKey) -> Bool {
        guard !touch.isActive, let bounds = display.currentBounds() else { return false }
        if !options.observe && !CGPreflightPostEventAccess() {
            log("Accessibility is no longer granted; exiting so the panel goes back to macOS")
            exitForRetry()
        }
        touchBounds = bounds
        activeSource = key
        return true
    }

    private func drive(_ sample: PointerSample, from key: SourceKey, bytes: [UInt8], time: TimeInterval) {
        guard let bounds = touchBounds else { return }
        let point = DisplayMapper.point(x: sample.x, y: sample.y, onto: bounds)
        let partner = sample.partner.map { DisplayMapper.point(x: $0.x, y: $0.y, onto: bounds) }
        let actions = touch.step(sample, at: point, partner: partner, time: time)

        if (options.observe && !actions.isEmpty) || traced < options.trace {
            traced += 1
            log("report [\(hex(bytes))] buttons=\(sample.buttons) x=\(String(format: "%.4f", sample.x)) y=\(String(format: "%.4f", sample.y)) -> \(actions)")
        }
        if !options.observe {
            actions.forEach(poster.post)
        }
        if !touch.isActive {
            activeSource = nil
            touchBounds = nil
        }
        armHoldTimer()
    }

    /// Wakes the gesture recognizer when something is due with no report to
    /// carry it: a resting finger becoming a hold (panels that send nothing
    /// while a finger rests), or a tap's release.
    private func armHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
        guard let deadline = touch.deadline else { return }
        let timer = Timer(timeInterval: max(0, deadline - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            // Silence wins: a touch that has gone quiet for the lift timeout
            // lost its lift, and must not press as a resting finger now.
            if self.touch.isActive, let timeout = self.options.liftTimeout, now - self.lastEvidence >= timeout {
                self.releaseHeld(reason: "no report for \(Int(timeout * 1000)) ms")
                return
            }
            let actions = self.touch.tick(now)
            if !self.options.observe {
                actions.forEach(self.poster.post)
            } else if !actions.isEmpty {
                log("timer -> \(actions)")
            }
            self.armHoldTimer()
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    /// A lost lift must not leave anything down for good: when the panel goes
    /// quiet while a touch is held, half-reported, or still recorded as
    /// touching, everything is released as if every finger had lifted.
    private func armLiftTimer(after key: SourceKey, at time: TimeInterval) {
        // While a touch is held only its own stream proves it is alive;
        // chatter from another stream must not keep a stuck press going.
        if touch.isActive, activeSource != key { return }
        lastEvidence = time
        liftTimer?.invalidate()
        liftTimer = nil
        guard let timeout = options.liftTimeout,
              touch.isActive || interfaces.contains(where: \.isBusy) else { return }
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            self?.releaseHeld(reason: "no report for \(Int(timeout * 1000)) ms")
        }
        RunLoop.main.add(timer, forMode: .common)
        liftTimer = timer
    }
}

// MARK: - Main

setvbuf(stdout, nil, _IOLBF, 0)
let options: RunOptions
switch parseCommand(CommandLine.arguments) {
case .listDevices:
    listDevices()
    exit(0)
case .listDisplays:
    listDisplays()
    exit(0)
case let .run(parsed):
    options = parsed
}

let features = [(options.multitouch, "multitouch"), (options.gestures, "gestures"), (options.pinch, "pinch")]
    .filter(\.0).map { ", \($0.1)" }.joined()
log("touchscreen-display-mapper starting (\(options.observe ? "observe" : "seize") mode\(features))")
guard permissionsReady(observe: options.observe) else {
    log("exiting so launchd relaunches with a fresh permission check")
    exit(exitRetry)
}
let bridge = TouchBridge(options: options)

// Stopping mid-touch must not leave a synthetic button held down. A clean
// stop exits 0, which launchd (SuccessfulExit=false) does not restart.
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        bridge.releaseHeld(reason: "stopping on signal \(signalNumber)")
        bridge.restoreModes()
        log("stopped by signal \(signalNumber)")
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

bridge.start()
CFRunLoopRun()
