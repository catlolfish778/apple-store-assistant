import Foundation

/// A task-scoped, append-only diagnostic trace. Never stores cookies, form values,
/// page text, request bodies, addresses, account details, or payment information.
struct TaskRecordingEvent: Codable {
    let sequence: Int
    let atUTC: String
    let elapsedMS: Double
    let releaseDeltaMS: Double?
    let name: String
    let runState: String
    let step: Int
    let details: [String: String]
}

struct TaskRecordingManifest: Codable {
    let formatVersion: Int
    let runID: String
    let planID: String
    let partNumber: String
    let scheduledAtUTC: String
    let createdAtUTC: String
    let privacy: String
}

@MainActor
final class TaskRecording {
    let directory: URL
    private let handle: FileHandle
    private let startedUptime = ProcessInfo.processInfo.systemUptime
    private var sequence = 0
    private var closed = false

    init(root: URL, run: RunRecord) throws {
        guard UUID(uuidString: run.id) != nil else { throw AppError("任务录制编号无效") }
        let parent = root.appendingPathComponent("task-recordings", isDirectory: true)
        directory = parent.appendingPathComponent(run.id, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw AppError("任务录制目录已存在，不会覆盖") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let formatter = Self.dateFormatter()
        let manifest = TaskRecordingManifest(
            formatVersion: 1, runID: run.id, planID: run.plan.id,
            partNumber: run.plan.variant.partNumber,
            scheduledAtUTC: formatter.string(from: run.plan.releaseAt),
            createdAtUTC: formatter.string(from: Date()),
            privacy: "仅记录任务状态、官网路径和购买按钮状态；不记录账号、地址、付款、Cookie、页面正文或请求内容"
        )
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        guard FileManager.default.createFile(atPath: eventsURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw AppError("无法创建任务录制时间线")
        }
        handle = try FileHandle(forWritingTo: eventsURL)
    }

    func append(_ name: String, run: RunRecord, releaseUptime: TimeInterval?, details: [String: String] = [:]) throws {
        guard !closed else { return }
        sequence += 1
        let now = ProcessInfo.processInfo.systemUptime
        let entry = TaskRecordingEvent(
            sequence: sequence,
            atUTC: Self.dateFormatter().string(from: Date()),
            elapsedMS: (now - startedUptime) * 1000,
            releaseDeltaMS: releaseUptime.map { (now - $0) * 1000 },
            name: name, runState: run.state, step: run.step, details: details
        )
        let data = try JSONEncoder().encode(entry) + Data([0x0a])
        try handle.write(contentsOf: data)
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
    }

    deinit { try? handle.close() }

    private static func dateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
