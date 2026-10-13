import Foundation
import Testing
@testable import TouchMapperCore

/// A fake installed binary in its own temporary directory, removed afterwards.
private func withInstalledBinary(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PermissionRequestTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    let binary = directory.appendingPathComponent("touchscreen-display-mapper")
    try Data([0]).write(to: binary)
    try reinstall(binary, at: Date(timeIntervalSince1970: 1_000))
    try body(binary)
}

/// What the installer does to the binary's modification time.
private func reinstall(_ binary: URL, at date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: binary.path)
}

private extension PermissionRequest.Outcome {
    var isAsked: Bool { if case .asked = self { return true } else { return false } }
    var isAlreadyAsked: Bool { if case .alreadyAsked = self { return true } else { return false } }
    var isNotRecorded: Bool { if case .notRecorded = self { return true } else { return false } }
}

struct PermissionRequestTests {
    @Test func aBinaryAsksOnceAndNeverOnLaterStarts() throws {
        try withInstalledBinary { binary in
            var asked = 0
            #expect(PermissionRequest(binary: binary, name: "accessibility").ask { asked += 1 }.isAsked)
            #expect(PermissionRequest(binary: binary, name: "accessibility").ask { asked += 1 }.isAlreadyAsked)
            #expect(PermissionRequest(binary: binary, name: "accessibility").ask { asked += 1 }.isAlreadyAsked)
            #expect(asked == 1)
        }
    }

    @Test func eachPermissionIsAskedForOnItsOwn() throws {
        try withInstalledBinary { binary in
            var asked = 0
            _ = PermissionRequest(binary: binary, name: "accessibility").ask { asked += 1 }
            #expect(PermissionRequest(binary: binary, name: "input-monitoring").ask { asked += 1 }.isAsked)
            #expect(asked == 2)
        }
    }

    /// Any new modification time counts, even an earlier one (a binary copied
    /// with its date kept, or a clock that was off).
    @Test func aReinstalledBinaryAsksOnceAgain() throws {
        try withInstalledBinary { binary in
            var asked = 0
            _ = PermissionRequest(binary: binary, name: "accessibility").ask { asked += 1 }
            try reinstall(binary, at: Date(timeIntervalSince1970: 500))
            #expect(PermissionRequest(binary: binary, name: "accessibility").ask { asked += 1 }.isAsked)
            #expect(PermissionRequest(binary: binary, name: "accessibility").ask { asked += 1 }.isAlreadyAsked)
            #expect(asked == 2)
        }
    }

    /// Asking without a record would ask on every start: the bug this prevents.
    @Test func nothingIsAskedWhenTheRequestCannotBeRecorded() throws {
        try withInstalledBinary { binary in
            let directory = binary.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            var asked = 0
            #expect(PermissionRequest(binary: binary, name: "accessibility").ask { asked += 1 }.isNotRecorded)
            #expect(asked == 0)
        }
    }

    @Test func nothingIsAskedForABinaryThatIsNotThere() throws {
        try withInstalledBinary { binary in
            let missing = binary.deletingLastPathComponent().appendingPathComponent("gone")
            var asked = 0
            #expect(PermissionRequest(binary: missing, name: "accessibility").ask { asked += 1 }.isNotRecorded)
            #expect(asked == 0)
        }
    }

    @Test func theMarkerSitsBesideTheBinaryAndIsHidden() {
        let binary = URL(fileURLWithPath: "/Users/someone/.touchscreen-display-mapper/bin/touchscreen-display-mapper")
        #expect(PermissionRequest(binary: binary, name: "input-monitoring").marker.path
                == "/Users/someone/.touchscreen-display-mapper/bin/.touchscreen-display-mapper.asked-input-monitoring")
    }
}
