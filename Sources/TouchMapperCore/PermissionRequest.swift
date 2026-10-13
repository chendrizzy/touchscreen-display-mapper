import Foundation

/// Asks for a privacy permission at most once per installed binary. Every
/// request queues another system prompt, and launchd restarts the agent every
/// 30 seconds while it waits for a grant, so asking on every start once stacked
/// 422 prompts that kept reappearing after the grant. A marker file next to the
/// binary holds the binary's modification time when it asked; a reinstall
/// writes a new binary, so the first start after it asks once again.
public struct PermissionRequest {
    public enum Outcome {
        case asked
        case alreadyAsked
        /// Nothing was asked: without a record, every start would ask again.
        case notRecorded(Error)
    }

    public let marker: URL
    let binary: URL

    /// `name` tells the permissions apart, e.g. "input-monitoring".
    public init(binary: URL, name: String) {
        self.binary = binary
        marker = binary.deletingLastPathComponent()
            .appendingPathComponent(".\(binary.lastPathComponent).asked-\(name)")
    }

    /// Calls `request` unless this binary already asked. The request is
    /// recorded first, so a crash in between cannot ask twice.
    public func ask(_ request: () -> Void) -> Outcome {
        do {
            let installed = try installedStamp()
            if (try? String(contentsOf: marker, encoding: .utf8)) == installed { return .alreadyAsked }
            try installed.write(to: marker, atomically: true, encoding: .utf8)
        } catch {
            return .notRecorded(error)
        }
        request()
        return .asked
    }

    /// The binary's modification time, which every install changes.
    private func installedStamp() throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: binary.path)
        guard let date = attributes[.modificationDate] as? Date else { throw CocoaError(.fileReadUnknown) }
        return "\(date.timeIntervalSince1970)"
    }
}
