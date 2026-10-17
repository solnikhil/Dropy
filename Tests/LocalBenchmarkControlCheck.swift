import Foundation

@main
struct BenchmarkControlCheck {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var actions: [String] = []
        let control = BenchmarkControl(directory: directory.path) { action in
            actions.append(action)
            return ["state": "closed", "answer": 42]
        }
        let ready = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("ready.json"))) as! [String: Any]
        precondition(ready["state"] as? String == "closed")
        let id = UUID().uuidString
        let payload = String(data: try JSONSerialization.data(withJSONObject: ["id": id, "action": "snapshot"]), encoding: .utf8)!
        DistributedNotificationCenter.default().postNotificationName(.init("org.dropy.benchmark.\(directory.lastPathComponent)"), object: payload, userInfo: nil, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(3)
        let reply = directory.appendingPathComponent("\(id).json")
        while !FileManager.default.fileExists(atPath: reply.path) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: reply)) as! [String: Any]
        precondition(value["id"] as? String == id && value["answer"] as? Int == 42)
        precondition(actions == ["snapshot", "snapshot"])
        // A malformed command must not become a filename or execute a handler.
        DistributedNotificationCenter.default().postNotificationName(.init("org.dropy.benchmark.\(directory.lastPathComponent)"), object: "{\"id\":\"../escape\",\"action\":\"quit\"}", userInfo: nil, deliverImmediately: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        precondition(actions == ["snapshot", "snapshot"])
        withExtendedLifetime(control) {}
        print("Benchmark control checks passed (real notification/reply, malformed request refused; no windows)")
    }
}
