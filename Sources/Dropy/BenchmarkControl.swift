import Foundation

/// Opt-in, local benchmark control. No timer or observer exists in ordinary launches.
/// The harness supplies a private, per-process directory and keeps every reply as evidence.
@MainActor
final class BenchmarkControl {
    private let directory: URL
    private var observer: NotificationObservation?
    private let handle: (String) -> [String: Any]

    init(directory: String, handle: @escaping (String) -> [String: Any]) {
        self.directory = URL(fileURLWithPath: directory, isDirectory: true)
        self.handle = handle
        observer = NotificationObservation(center: DistributedNotificationCenter.default(),
            forName: .init("org.dropy.benchmark.\(self.directory.lastPathComponent)"),
            object: nil, queue: .main) { [weak self] notification in
                guard let text = notification.object as? String else { return }
                MainActor.assumeIsolated { self?.receive(text) }
            }
        write(handle("snapshot"), id: "ready")
    }

    private func receive(_ text: String) {
        guard let data = text.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let id = request["id"], UUID(uuidString: id) != nil,
              let action = request["action"] else { return }
        write(handle(action), id: id)
    }

    private func write(_ value: [String: Any], id: String) {
        var reply = value
        reply["id"] = id
        reply["pid"] = getpid()
        reply["uptimeNs"] = String(DispatchTime.now().uptimeNanoseconds)
        do {
            let data = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
            try data.write(to: directory.appendingPathComponent("\(id).json"), options: .atomic)
        } catch {
            NSLog("Dropy benchmark: reply failed: %@", String(describing: error))
        }
    }
}
