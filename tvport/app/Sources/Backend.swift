import Foundation

// tvport/backend.py, as the app sees it: one JSON answer, or a stream of events for a build.

struct AppleTV: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let model: String?
    let os: String?
    let connected: Bool
    let developer_mode: Bool
    var title: String { [name, model].compactMap { $0 }.joined(separator: " · ") }
}

struct Signing: Codable, Hashable {
    let team: String?
    let expires: String?
    let days_left: Int?
    let free_team: Bool?
}

struct GameInfo: Codable {
    let folder: String
    let title_id: String
    let name: String
    let version: String
    let sources: [String]
    let prepared: Bool
    let icon: String?
    let team: String?
    let bundle_id: String?
    let signing: Signing?
    let keys: String?
    let last_backup: String?
}

struct SaveBackup: Codable {
    let files: Int
    let folder: String?
    let changed: Bool
}

struct RunLog: Codable {
    let last_frame: Int
    let peak_mb: Double
    let gpu_mb: Double
    let min_headroom_mb: Double?
    let hitches: Int
    let worst_ms: Double
    let texture_ms: Double
    let pipeline_ms: Double
    let gpu_slow_frames: Int
}

struct Diagnosis: Codable {
    let run: RunLog
    let verdicts: [String]
    let log: String
}

enum BuildEvent {
    case stage(String)
    case log(String)
    case progress(Double)
    case failed(String)
    case done(bundle: String, signing: Signing?)
}

struct BackendError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Backend {
    /// Set at build time to the project folder (project.yml).
    static var root: URL {
        let value = Bundle.main.object(forInfoDictionaryKey: "TVPortRoot") as? String ?? ""
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    private static func process(_ arguments: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [root.appendingPathComponent("tvport/backend.py").path] + arguments
        p.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/local/share/dotnet:/usr/bin:/bin:/usr/sbin:/sbin"   // an app opened from Finder has no shell PATH: the engine needs xcodegen, dotnet and glslang
        environment["PYTHONUNBUFFERED"] = "1"
        p.environment = environment
        return p
    }

    /// A command that answers with one JSON object.
    static func ask<T: Decodable>(_ type: T.Type, _ arguments: [String]) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            let p = process(arguments)
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let failure = try? JSONDecoder().decode([String: String].self, from: data), let message = failure["error"] {
                throw BackendError(message: message)
            }
            do { return try JSONDecoder().decode(T.self, from: data) } catch {
                throw BackendError(message: "The backend gave an unreadable answer: \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
            }
        }.value
    }

    /// `build`: events as they happen. Cancelling the task stops the build.
    static func build(_ arguments: [String]) -> AsyncStream<BuildEvent> {
        AsyncStream { continuation in
            let p = process(["build"] + arguments)
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            let reader = LineReader { line in
                if let event = parse(line) { continuation.yield(event) }
            }
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; reader.finish(); continuation.finish() } else { reader.add(data) }
            }
            continuation.onTermination = { _ in if p.isRunning { p.terminate() } }
            do { try p.run() } catch {
                continuation.yield(.failed("Could not start the backend: \(error.localizedDescription)"))
                continuation.finish()
            }
        }
    }

    private struct Wire: Decodable {
        let event: String
        var name: String?
        var line: String?
        var value: Double?
        var message: String?
        var bundle_id: String?
        var signing: Signing?
    }

    static func parse(_ line: String) -> BuildEvent? {
        guard let data = line.data(using: .utf8), let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            return line.isEmpty ? nil : .log(line)   // anything not from the backend itself (a Python traceback) still reaches the log
        }
        switch wire.event {
        case "stage": return .stage(wire.name ?? "")
        case "log": return .log(wire.line ?? "")
        case "progress": return .progress(wire.value ?? 0)
        case "error": return .failed(wire.message ?? "The build failed")
        case "done": return .done(bundle: wire.bundle_id ?? "", signing: wire.signing)
        default: return nil
        }
    }
}

/// Splits a pipe's chunks into lines; a chunk can end mid-line.
final class LineReader: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func add(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        while let end = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<end]
            pending = Data(pending[pending.index(after: end)...])
            onLine(String(decoding: line, as: UTF8.self))
        }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)); pending = Data() }
    }
}
