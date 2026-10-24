import Foundation
import CoreGraphics

/// One JSON object per line. All file work is serialized off the UI thread.
final class EventLog {
    static let shared = EventLog()
    private let queue = DispatchQueue(label: "local.windowoffset.log", qos: .utility)
    let fileURL: URL
    private let limit: Int

    init(fileURL: URL? = nil, limit: Int = 2 * 1024 * 1024) {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        self.fileURL = fileURL ?? library.appendingPathComponent("Logs/WindowOffset/events.jsonl")
        self.limit = limit
    }

    func write(_ event: String, _ fields: [String: Any] = [:]) {
        var entry = fields
        entry["event"] = event
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        entry["time"] = formatter.string(from: Date())
        entry["sessionPID"] = ProcessInfo.processInfo.processIdentifier
        queue.async { [self] in
            do {
                let manager = FileManager.default
                try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let bytes = try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber,
                   bytes.intValue >= limit {
                    let oldest = fileURL.appendingPathExtension("3")
                    if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
                    for index in stride(from: 2, through: 1, by: -1) {
                        let source = fileURL.appendingPathExtension(String(index))
                        if manager.fileExists(atPath: source.path) {
                            try manager.moveItem(at: source, to: fileURL.appendingPathExtension(String(index + 1)))
                        }
                    }
                    try manager.moveItem(at: fileURL, to: fileURL.appendingPathExtension("1"))
                }
                var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
                data.append(0x0A)
                if !manager.fileExists(atPath: fileURL.path) {
                    manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                fputs("WindowOffset log error: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    func flush() { queue.sync {} }
    static func rect(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
    }
}
