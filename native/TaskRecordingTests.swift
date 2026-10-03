import Foundation

@main struct TaskRecordingTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-recording-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let variant = Variant(partNumber: "DEMO001/A", family: "test", selections: [:], label: "Demo", url: "https://www.apple.com.cn/shop/product/demo", price: 100, comingSoon: true)
        let plan = Plan(name: "test", source: variant.url, variant: variant, catalogHash: "test", releaseAt: Date().addingTimeInterval(60))
        var run = RunRecord(plan: plan)
        let recording = try TaskRecording(root: root, run: run)
        try recording.append("armed", run: run, releaseUptime: ProcessInfo.processInfo.systemUptime + 60)
        run.state = "executing"
        try recording.append("product_check", run: run, releaseUptime: ProcessInfo.processInfo.systemUptime, details: ["status": "waiting"])
        recording.close()
        let manifest = try JSONDecoder().decode(TaskRecordingManifest.self, from: Data(contentsOf: recording.directory.appendingPathComponent("manifest.json")))
        assert(manifest.runID == run.id && manifest.partNumber == variant.partNumber)
        let eventsURL = recording.directory.appendingPathComponent("events.jsonl")
        let lines = try String(contentsOf: eventsURL, encoding: .utf8).split(separator: "\n")
        assert(lines.count == 2)
        let events = try lines.map { try JSONDecoder().decode(TaskRecordingEvent.self, from: Data($0.utf8)) }
        assert(events.map(\.sequence) == [1, 2])
        assert(events[1].name == "product_check" && events[1].details["status"] == "waiting")
        assert(events[1].releaseDeltaMS != nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: eventsURL.path)[.posixPermissions] as? NSNumber
        assert(permissions?.intValue == 0o600)
        do { _ = try TaskRecording(root: root, run: run); fatalError("existing run was overwritten") } catch {}
        print("Task recording tests passed: separate run, ordered timeline, permissions, no overwrite")
    }
}
