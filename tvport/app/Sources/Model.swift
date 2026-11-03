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
    var renderScale: Double?   // the 3D views at this fraction of the game's size, for games with a render-scale stub; nil = full size. Optional: library.json saved before it decodes as is
    var coolWhenHot: Bool?     // frame-step games hold 30 fps while the TV is thermally serious; nil = on (the engine's default)
    var fpsTarget: Int?        // 30 or 60 in place of the profile's fps_target; nil = the profile's
    var showFPS = true
    var players: String?
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
    @Published var setup: SetupReport?
    @Published var settingUp = false
    @Published var setupStage = ""
    @Published var setupFailure: String?
    @Published var showingSetup = false
    @Published var backups: [String: BackupStatus] = [:]
    @Published var icloudBackups = UserDefaults.standard.bool(forKey: "BackUpToICloud") {
        didSet { UserDefaults.standard.set(icloudBackups, forKey: "BackUpToICloud") }
    }
    @Published var icloudAvailable = true
    private var building: Task<Void, Never>?
    private static let backupInterval: Double = 300
    private static let retryInterval: Double = 60   // while the TV cannot be reached, so a round comes soon after it can

    private static let store = Backend.data.appendingPathComponent("library.json")
    private static let previews = FileManager.default.temporaryDirectory.appendingPathComponent("TVPortPreviews", isDirectory: true)

    init() {
        if let data = try? Data(contentsOf: Self.store), let saved = try? JSONDecoder().decode([Game].self, from: data) { games = saved }
        selection = games.first?.id
        try? FileManager.default.createDirectory(at: Self.previews, withIntermediateDirectories: true)
    }

    var current: Game? { games.first { $0.id == selection } }
    var isBusy: Bool { run == .running || settingUp }
    /// Unknown until the first check, which then does not hold anything back.
    var setupMissing: [Check] { setup?.checks.filter { !$0.ok } ?? [] }
    var bundleID: String? { info?.bundle_id }
    /// One prod.keys serves every game: this game's pick, then any other game's, then where the backend found one.
    var keys: String? { current?.keys ?? games.compactMap(\.keys).first ?? info?.keys }

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
        if let scale = game.renderScale, scale < 1, info?.render_scale == true { arguments += ["--render-scale", String(scale)] }
        if game.coolWhenHot == false, info?.frame_step == true { arguments.append("--no-thermal-cap") }
        if let fps = game.fpsTarget, (info?.fps_target ?? 0) != 0, fps != info?.fps_target { arguments += ["--fps-target", String(fps)] }
        if !team.isEmpty { arguments += ["--team", team] }
        if let keys { arguments += ["--keys", keys] }
        if let players = game.players, !players.isEmpty { arguments += ["--players", players] }
        if let art = game.artwork { arguments += ["--art", art] }
        if icloudBackups { arguments.append("--icloud") }
        if install, let device { arguments += ["--device", device] }
        run = .running; stage = "Starting"; progress = nil; log = []; notice = nil
        building = Task {
            var finished = false
            for await event in Backend.stream(["build"] + arguments) {
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

    /// What a build needs from this Mac. The first start of each release also unpacks the engine and makes its Python, without being asked.
    func checkSetup() async {
        guard Backend.developerFolder != nil else {
            setup = SetupReport(checks: [Check(name: "Xcode", ok: false, detail: "Not installed", fix: "Install Xcode from the App Store, open it once, then press Check Again.", command: "")],
                                ready: false, needs_setup: false, can_set_up: false)
            showingSetup = true
            return
        }
        do {
            let report = try await Backend.ask(SetupReport.self, ["doctor"])
            setup = report
            if report.needs_setup && report.can_set_up && !settingUp && setupFailure == nil { runSetup() }
        } catch { setupFailure = error.localizedDescription }
    }

    func runSetup() {
        guard !settingUp, run != .running else { return }
        settingUp = true; setupStage = "Starting"; setupFailure = nil
        Task {
            var failed: String?
            for await event in Backend.stream(["setup"]) {
                switch event {
                case .stage(let name): setupStage = name; append(name)
                case .log(let line): append(line)
                case .failed(let message): failed = message
                case .progress, .done: break
                }
            }
            settingUp = false; setupStage = ""; setupFailure = failed
            await checkSetup()
        }
    }

    func backUpSaves() {
        guard let game = current, let device, let bundleID else { return }
        notice = "Copying saves from the Apple TV…"
        Task {
            do {
                let backup = try await Backend.ask(SaveBackup.self, ["backup", game.folder, "--device", device, "--bundle", bundleID] + (icloudBackups ? ["--icloud"] : []))
                switch backup.state {
                case "unavailable": notice = "The Apple TV did not answer. Wake it with the remote, then try again."
                case "busy": notice = "The game was saving during each copy. Try again in a moment."
                default: notice = backup.files == 0 ? "The Apple TV has no saves for this game yet." : backup.changed ? "\(backup.files) save files backed up." : "The backup is already up to date."
                }
                await refresh()
            } catch { notice = error.localizedDescription }
        }
    }

    /// While the app is open: a round when it opens, then every few minutes, and soon after the TV can be reached again.
    func backUpEveryFewMinutes() async {
        while !Task.isCancelled {
            let wait = await backUpRound()
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    /// One round of automatic backups of every built game. It only reads the TV (backend.py autobackup), and is quiet when the TV is asleep or away, or the game is not installed.
    private func backUpRound() async -> Double {
        if devices.isEmpty { await refreshDevices() }
        let folders = games.filter { !$0.titleID.isEmpty }.map(\.folder)
        guard let device else { return Self.retryInterval }
        guard !folders.isEmpty, run != .running else { return Self.backupInterval }   // a build backs up first anyway
        let arguments = ["autobackup", "--device", device] + folders.flatMap { ["--folder", $0] } + (icloudBackups ? ["--icloud"] : [])
        guard let round = try? await Backend.ask(BackupRound.self, arguments) else { return Self.backupInterval }
        icloudAvailable = round.icloud
        for (folder, var status) in round.games {
            status.checked = status.checked ?? backups[folder]?.checked   // a round that could not ask keeps the last time the copy matched the TV
            backups[folder] = status
        }
        return round.state == "unreachable" ? Self.retryInterval : Self.backupInterval
    }

    /// When the Mac's copy of a game's saves last matched the TV, or when its newest backup was made.
    func backedUp(_ game: Game) -> String? {
        let status = backups[game.folder]
        let time = status?.checked ?? status?.last_backup_time ?? (game.id == selection ? info?.last_backup_time : nil)
        guard let time else { return nil }
        let date = Date(timeIntervalSince1970: time)
        return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
    }

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
