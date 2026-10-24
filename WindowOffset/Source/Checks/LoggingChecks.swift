import Foundation

@main
enum LoggingChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WindowOffset-log-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.jsonl")
        let logger = EventLog(fileURL: file)
        for index in 0..<20 {
            logger.write("synthetic_operation", ["index": index, "app": "示例应用", "axError": 0,
                "frame": EventLog.rect(CGRect(x: 1.5, y: -20, width: 400, height: 300))])
        }
        logger.flush()
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        precondition(lines.count == 20)
        for (index, line) in lines.enumerated() {
            let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            precondition(record["index"] as? Int == index)
            precondition(record["time"] is String && record["sessionPID"] is Int)
            precondition(record["app"] as? String == "示例应用")
            precondition((record["frame"] as? [String: Double])?["x"] == 1.5)
        }
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue & 0o777 == 0o600)
        let rotating = EventLog(fileURL: file, limit: 1)
        for index in 0..<10 { rotating.write("rotation", ["index": index]) }
        rotating.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        precondition(files == ["events.jsonl", "events.jsonl.1", "events.jsonl.2", "events.jsonl.3"])
        let latest = try String(contentsOf: file, encoding: .utf8)
        let record = try JSONSerialization.jsonObject(with: Data(latest.utf8)) as! [String: Any]
        precondition(record["index"] as? Int == 9)
        print("PASS: JSONL, ordering, Unicode, geometry, flush, file permissions and bounded rotation")
        print("Synthetic logger checks only; no desktop windows were accessed.")
    }
}
