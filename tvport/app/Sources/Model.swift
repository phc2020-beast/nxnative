import Foundation
import SwiftUI

enum RenderMode: String, Codable, CaseIterable, Identifiable {
    case handheld, docked
    var id: String { rawValue }
    var label: String { self == .handheld ? "Handheld (720p)" : "Docked (900p)" }
    var note: String {
        self == .handheld ? "Lighter on the GPU and on memory. Some games lose motion controls in this mode."
                          : "Sharper, but the A15 can't always hold it, and it leaves less memory."
    }
}

enum TextureDetail: Int, Codable, CaseIterable, Identifiable {
    case full = 0, high = 1024, medium = 512, low = 256
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .full: return "Full"
        case .high: return "High (1024)"
        case .medium: return "Medium (512)"
        case .low: return "Low (256)"
        }
    }
}

struct Game: Codable, Identifiable, Hashable {
    var folder: String
    var name: String
    var titleID = ""
    var artwork: String?
    var keys: String?
    var mode: RenderMode = .handheld
    var texture: TextureDetail = .medium
    var showFPS = true
    var id: String { folder }
}

enum Run: Equatable {
    case idle, running, succeeded, failed(String)
}

@MainActor
final class Library: ObservableObject {
    @Published var games: [Game] = []
    @Published var selection: Game.ID?
    @Published var info: GameInfo?
    @Published var preview: NSImage?
    @Published var devices: [AppleTV] = []
    @Published var device: AppleTV.ID?
    @Published var team = ""
    @Published var run = Run.idle
    @Published var stage = ""
    @Published var progress: Double?
    @Published var log: [String] = []
    @Published var diagnosis: Diagnosis?
    @Published var notice: String?
    private var building: Task<Void, Never>?

    private static let store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TVPort/library.json")
    private static let previews = FileManager.default.temporaryDirectory.appendingPathComponent("TVPortPreviews", isDirectory: true)

    init() {
        if let data = try? Data(contentsOf: Self.store), let saved = try? JSONDecoder().decode([Game].self, from: data) { games = saved }
        selection = games.first?.id
        try? FileManager.default.createDirectory(at: Self.previews, withIntermediateDirectories: true)
    }

    var current: Game? { games.first { $0.id == selection } }
    var isBusy: Bool { run == .running }
    var bundleID: String? { info?.bundle_id }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.store.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(games) { try? data.write(to: Self.store) }
    }

    func update(_ change: (inout Game) -> Void) {
        guard let index = games.firstIndex(where: { $0.id == selection }) else { return }
        change(&games[index])
        save()
    }

    func add(folder: URL) {
        if !games.contains(where: { $0.folder == folder.path }) {
            games.append(Game(folder: folder.path, name: folder.lastPathComponent))
            save()
        }
        selection = folder.path
    }

    func remove(_ game: Game) {
        games.removeAll { $0.id == game.id }
        save()
        if selection == game.id { selection = games.first?.id }
    }

    /// Reads the selected game's folder and refreshes the Apple TV list.
    func refresh() async {
        info = nil; preview = nil; diagnosis = nil; notice = nil
        await refreshDevices()
        guard let game = current else { return }
        do {
            let found = try await Backend.ask(GameInfo.self, ["inspect", game.folder])
            guard selection == game.id else { return }
            info = found
            if team.isEmpty, let known = found.team { team = known }
            update { $0.name = found.name; $0.titleID = found.title_id }
            await renderPreview()
        } catch { notice = error.localizedDescription }
    }

    func refreshDevices() async {
        struct Answer: Decodable { let devices: [AppleTV] }
        guard let answer = try? await Backend.ask(Answer.self, ["devices"]) else { return }
        devices = answer.devices
        if device == nil || !devices.contains(where: { $0.id == device }) { device = devices.first?.id }
    }

    func setArtwork(_ url: URL?) {
        update { $0.artwork = url?.path }
        Task { await renderPreview() }
    }

    /// The same drawing the build uses (tv_icon.swift), so what shows here is what the TV shows.
    func renderPreview() async {
        guard let art = current?.artwork ?? info?.icon else { preview = nil; return }
        let out = Self.previews.appendingPathComponent(UUID().uuidString + ".png")
        struct Answer: Decodable { let preview: String }
        do {
            _ = try await Backend.ask(Answer.self, ["preview", "--art", art, "--out", out.path])
            preview = NSImage(contentsOf: out)
            try? FileManager.default.removeItem(at: out)
        } catch {
            preview = nil
            notice = "That artwork could not be read: \(error.localizedDescription)"
        }
    }

    func build(install: Bool) {
        guard let game = current, !isBusy else { return }
        var arguments = [game.folder, "--mode", game.mode.rawValue, "--texture-cap", String(game.texture.rawValue)]
        if game.showFPS { arguments.append("--fps") }
        if !team.isEmpty { arguments += ["--team", team] }
        if let keys = game.keys { arguments += ["--keys", keys] }
        if let art = game.artwork { arguments += ["--art", art] }
        if install, let device { arguments += ["--device", device] }
        run = .running; stage = "Starting"; progress = nil; log = []; notice = nil
        building = Task {
            var finished = false
            for await event in Backend.build(arguments) {
                switch event {
                case .stage(let name): stage = name; progress = nil; append(name)
                case .log(let line): append(line)
                case .progress(let value): progress = value
                case .failed(let message): run = .failed(message); finished = true
                case .done: run = .succeeded; stage = install ? "Installed on the Apple TV" : "Built"; progress = nil; finished = true
                }
            }
            if !finished { run = Task.isCancelled ? .idle : .failed("The build stopped without saying why. See the log.") }
            await refresh()
        }
    }

    func cancel() { building?.cancel(); stage = "Stopped"; run = .idle }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 4000 { log.removeFirst(log.count - 4000) }
    }

    func launch() {
        guard let device, let bundleID else { return }
        notice = nil
        Task {
            struct Answer: Decodable { let launched: String }
            do { _ = try await Backend.ask(Answer.self, ["launch", "--device", device, "--bundle", bundleID]) } catch { notice = error.localizedDescription }
        }
    }

    func diagnose() {
        guard let device, let bundleID else { return }
        notice = "Reading the last run from the Apple TV…"
        Task {
            do { diagnosis = try await Backend.ask(Diagnosis.self, ["diagnose", "--device", device, "--bundle", bundleID]); notice = nil } catch { notice = error.localizedDescription }
        }
    }
}
