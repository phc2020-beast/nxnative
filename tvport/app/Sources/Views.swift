import SwiftUI
import UniformTypeIdentifiers

@main
struct TVPortApp: App {
    @StateObject private var library = Library()

    var body: some Scene {
        WindowGroup("TVPort") {
            ContentView().environmentObject(library).frame(minWidth: 860, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    @EnvironmentObject var library: Library
    @State private var choosingFolder = false

    var body: some View {
        NavigationSplitView {
            List(library.games, selection: $library.selection) { game in
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.name).lineLimit(1)
                    Text(game.titleID.isEmpty ? "Not built yet" : game.titleID).font(.caption).foregroundStyle(.secondary)
                }
                .tag(game.id)
                .contextMenu { Button("Remove from List") { library.remove(game) } }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                Button { choosingFolder = true } label: { Label("Add Game", systemImage: "plus") }
                    .help("Add a folder holding your game's .nsp or .xci files")
            }
        } detail: {
            if library.current == nil {
                ContentUnavailableView {
                    Label("No games yet", systemImage: "appletv")
                } description: {
                    Text("Add a folder holding your own game's .nsp or .xci files, with any update or DLC.")
                } actions: {
                    Button("Add Game Folder…") { choosingFolder = true }.buttonStyle(.borderedProminent)
                }
            } else {
                GameView()
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { library.add(folder: folder) }
        }
        .task(id: library.selection) { await library.refresh() }
    }
}

struct GameView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Header()
                    if let notice = library.notice { NoticeBar(text: notice) }
                    HStack(alignment: .top, spacing: 20) {
                        ArtworkCard().frame(width: 300)
                        SettingsForm()
                    }
                    if let diagnosis = library.diagnosis { DiagnosisCard(diagnosis: diagnosis) }
                }
                .padding(20)
            }
            Divider()
            ProgressPanel()
        }
        .navigationTitle(library.current?.name ?? "TVPort")
        .toolbar {
            ToolbarItemGroup {
                Button("Last Run") { library.diagnose() }.disabled(library.bundleID == nil || library.device == nil || library.isBusy)
                    .help("Read memory and frame times from the Apple TV")
                Button("Open on TV") { library.launch() }.disabled(library.bundleID == nil || library.device == nil || library.isBusy)
                if library.isBusy {
                    Button("Stop", role: .cancel) { library.cancel() }
                } else {
                    Button("Build & Install") { library.build(install: true) }
                        .buttonStyle(.borderedProminent).keyboardShortcut("b").disabled(!canBuild)
                }
            }
        }
    }

    private var canBuild: Bool {
        guard let info = library.info, library.device != nil else { return false }
        return info.prepared || (!info.sources.isEmpty && library.current?.keys != nil)
    }
}

struct Header: View {
    @EnvironmentObject var library: Library

    var body: some View {
        if let info = library.info {
            VStack(alignment: .leading, spacing: 4) {
                Text(info.name).font(.title2.weight(.semibold))
                Text([info.version.isEmpty ? nil : "Version \(info.version)", info.title_id.isEmpty ? nil : info.title_id, info.prepared ? "Ready to build" : "First build takes 30 to 60 minutes"]
                    .compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                if let days = info.signing?.days_left, days < 3, info.signing?.free_team == true {
                    Label(days < 0 ? "This install's signature has expired, so the TV won't open it. Build & Install renews it." : "This install stops opening in \(days) day\(days == 1 ? "" : "s"). Build & Install renews it.",
                          systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange)
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

struct NoticeBar: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "info.circle").frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ArtworkCard: View {
    @EnvironmentObject var library: Library
    @State private var choosing = false
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple TV Icon").font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                if let preview = library.preview {
                    Image(nsImage: preview).resizable().aspectRatio(5.0 / 3.0, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo").font(.title)
                        Text("Drop an image here")
                    }.foregroundStyle(.secondary)
                }
                if targeted { RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, lineWidth: 3) }
            }
            .aspectRatio(5.0 / 3.0, contentMode: .fit)
            .accessibilityLabel("Apple TV icon preview. Drop an image to replace it.")
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                library.setArtwork(url)
                return true
            } isTargeted: { targeted = $0 }
            HStack {
                Button("Choose Artwork…") { choosing = true }
                if library.current?.artwork != nil { Button("Use Game's Icon") { library.setArtwork(nil) } }
            }
            Text("Any image works. Wide art fills the icon. Square art sits on a blurred copy of itself. The Top Shelf banner comes from the same image.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { library.setArtwork(url) }
        }
    }
}

struct SettingsForm: View {
    @EnvironmentObject var library: Library
    @State private var choosingKeys = false

    var body: some View {
        Form {
            Section("Apple TV") {
                Picker("Device", selection: $library.device) {
                    if library.devices.isEmpty { Text("None found").tag(AppleTV.ID?.none) }
                    ForEach(library.devices) { Text($0.title).tag(Optional($0.id)) }
                }
                TextField("Signing team", text: $library.team, prompt: Text("10-character team ID"))
                Button("Look Again") { Task { await library.refreshDevices() } }
            }
            Section("Performance") {
                Picker("Render mode", selection: binding(\.mode)) { ForEach(RenderMode.allCases) { Text($0.label).tag($0) } }
                Text(library.current?.mode.note ?? "").font(.caption).foregroundStyle(.secondary)
                Picker("Texture detail", selection: binding(\.texture)) { ForEach(TextureDetail.allCases) { Text($0.label).tag($0) } }
                Text("The A15 has to store these textures uncompressed, so lower detail saves memory and shortens loading.").font(.caption).foregroundStyle(.secondary)
                Toggle("Frame-rate counter", isOn: binding(\.showFPS))
            }
            if library.info?.prepared == false {
                Section("First Build") {
                    LabeledContent("prod.keys") {
                        HStack {
                            Text(library.current?.keys.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Not chosen").foregroundStyle(.secondary)
                            Button("Choose…") { choosingKeys = true }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped).scrollDisabled(true)
        .fileImporter(isPresented: $choosingKeys, allowedContentTypes: [.data, .item]) { result in
            if case .success(let url) = result { library.update { $0.keys = url.path } }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<Game, T>) -> Binding<T> {
        Binding(get: { library.current![keyPath: path] }, set: { value in library.update { $0[keyPath: path] = value } })
    }
}

struct DiagnosisCard: View {
    let diagnosis: Diagnosis

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last Run").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 4) {
                GridRow { stat("Peak memory", "\(Int(diagnosis.run.peak_mb)) MB"); stat("Long frames", "\(diagnosis.run.hitches)"); stat("Worst frame", "\(Int(diagnosis.run.worst_ms)) ms") }
                GridRow { stat("Closest to limit", diagnosis.run.min_headroom_mb.map { "\(Int($0)) MB left" } ?? "Not reported"); stat("Texture loading", "\(Int(diagnosis.run.texture_ms)) ms"); stat("Shaders", "\(Int(diagnosis.run.pipeline_ms)) ms") }
            }
            ForEach(diagnosis.verdicts, id: \.self) { Label($0, systemImage: "arrow.right.circle") }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit().weight(.medium))
        }
    }
}

struct ProgressPanel: View {
    @EnvironmentObject var library: Library
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                switch library.run {
                case .idle: Text(library.stage.isEmpty ? "Ready" : library.stage).foregroundStyle(.secondary)
                case .running:
                    ProgressView().controlSize(.small)
                    Text(library.stage).lineLimit(1)
                case .succeeded: Label(library.stage, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
                Spacer()
                Button(showLog ? "Hide Log" : "Show Log") { showLog.toggle() }.buttonStyle(.link)
            }
            if library.run == .running, let progress = library.progress { ProgressView(value: progress) }
            if case .failed(let message) = library.run {
                Text(message).font(.callout).textSelection(.enabled).lineLimit(8).foregroundStyle(.red)
            }
            if showLog {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(library.log.enumerated()), id: \.offset) { index, line in
                                Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 170)
                    .onChange(of: library.log.count) { _, count in reader.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
        .padding(12)
    }
}
