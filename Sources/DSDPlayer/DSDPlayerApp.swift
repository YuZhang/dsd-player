import SwiftUI
import AppKit
import MediaPlayer
import UniformTypeIdentifiers

// MARK: - 播放模式

enum PlayMode: Int, CaseIterable {
    case sequential   // 顺序播放（播完即止）
    case loopAll      // 列表循环
    case loopOne      // 单曲循环
    case shuffle      // 随机播放

    var icon: String {
        switch self {
        case .sequential: return "arrow.right.to.line"
        case .loopAll: return "repeat"
        case .loopOne: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }
    var label: String {
        switch self {
        case .sequential: return "顺序播放"
        case .loopAll: return "列表循环"
        case .loopOne: return "单曲循环"
        case .shuffle: return "随机播放"
        }
    }
    func next() -> PlayMode {
        let all = PlayMode.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

// MARK: - 播放列表项

struct PlaylistItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let info: DSDInfo
    var title: String { url.deletingPathExtension().lastPathComponent }
}

// MARK: - 播放模型

@MainActor
final class PlayerModel: ObservableObject {
    @Published var devices: [OutputDevice] = []
    @Published var selectedDevice: OutputDevice?
    @Published var playlist: [PlaylistItem] = []
    @Published var currentIndex: Int?
    @Published var playMode: PlayMode = .sequential {
        didSet {
            persist()
            queueNextForGapless()
        }
    }
    @Published var outputMode: OutputMode = .dop
    @Published var state: PlaybackEngine.State = .idle
    @Published var position: Double = 0
    @Published var statusMessage = ""

    let engine = PlaybackEngine()
    private var timer: Timer?
    private var queuedNextIndex: Int?   // 无缝预排的下一首

    // MARK: 持久化

    private struct SavedState: Codable {
        let paths: [String]
        let currentIndex: Int?
        let playMode: Int
        let outputMode: Int
    }
    private let persistKey = "DSDPlayer.savedState"
    private var isRestoring = false

    private func persist() {
        guard !isRestoring else { return }
        let saved = SavedState(paths: playlist.map { $0.url.path },
                               currentIndex: currentIndex,
                               playMode: playMode.rawValue,
                               outputMode: outputMode.rawValue)
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: persistKey)
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let saved = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        isRestoring = true
        defer {
            isRestoring = false
            persist()   // 写回规范化后的状态（已移除不存在的文件）
        }
        playMode = PlayMode(rawValue: saved.playMode) ?? .sequential
        outputMode = OutputMode(rawValue: saved.outputMode) ?? .dop
        engine.outputMode = outputMode
        var items: [PlaylistItem] = []
        var missing = 0
        for path in saved.paths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path),
                  let src = try? DSDFile.open(url) else { missing += 1; continue }
            items.append(PlaylistItem(url: url, info: src.info))
        }
        playlist = items
        if missing > 0 {
            statusMessage = "\(missing) 个文件已移动或删除，未恢复"
        }
        if let idx = saved.currentIndex, playlist.indices.contains(idx) {
            load(at: idx)
        }
    }

    var currentItem: PlaylistItem? {
        guard let i = currentIndex, playlist.indices.contains(i) else { return nil }
        return playlist[i]
    }
    var currentInfo: DSDInfo? { currentItem?.info }

    init() {
        refreshDevices()
        engine.onStateChange = { [weak self] s in
            guard let self else { return }
            // playAt 内部 load/stop 会派生 .stopped 事件，非播完路径无需处理
            self.state = s
            if s == .finished { self.advanceAfterFinish() }
        }
        engine.onError = { [weak self] msg in self?.statusMessage = msg }
        engine.onTrackAdvanced = { [weak self] in
            guard let self, let ni = self.queuedNextIndex,
                  self.playlist.indices.contains(ni) else { return }
            self.currentIndex = ni
            self.persist()
            self.queueNextForGapless()
            self.updateNowPlaying()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        setupRemoteCommands()
        restore()
    }

    private func tick() {
        guard state == .playing || state == .paused else { return }
        position = engine.positionSeconds
        updateNowPlaying()
    }

    // MARK: 无缝续播预排

    /// 按当前播放模式预排下一首，交给引擎在同规格时无缝衔接
    private func queueNextForGapless() {
        guard let idx = currentIndex, !playlist.isEmpty else {
            queuedNextIndex = nil
            engine.setNext(nil)
            return
        }
        let nextIdx: Int?
        switch playMode {
        case .loopOne: nextIdx = idx
        case .loopAll: nextIdx = (idx + 1) % playlist.count
        case .sequential: nextIdx = idx + 1 < playlist.count ? idx + 1 : nil
        case .shuffle: nextIdx = playlist.count > 1 ? randomIndex(excluding: idx) : idx
        }
        queuedNextIndex = nextIdx
        if let ni = nextIdx {
            engine.setNext(try? DSDFile.open(playlist[ni].url))
        } else {
            engine.setNext(nil)
        }
    }

    // MARK: 媒体键与 Now Playing

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.state == .paused || self.state == .stopped { self.togglePlay(); return .success }
            return .commandFailed
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.state == .playing else { return .commandFailed }
            self.togglePlay(); return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlay(); return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            self?.next(); return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous(); return .success
        }
    }

    func updateNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentItem?.title ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = currentInfo?.durationSeconds ?? 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = state == .playing ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: 设备

    func refreshDevices() {
        devices = AudioDeviceManager.outputDevices()
        if let current = selectedDevice, devices.contains(current) { return }
        if let def = AudioDeviceManager.defaultOutputDevice(),
           let dev = devices.first(where: { $0.id == def }) {
            selectedDevice = dev
        } else {
            selectedDevice = devices.first(where: { $0.isUSB }) ?? devices.first
        }
    }

    var deviceSupportsCarrier: Bool {
        guard let dev = selectedDevice, let info = currentInfo else { return true }
        return dev.supports(rate: activeOutputRate(for: info))
    }

    func activeOutputRate(for info: DSDInfo) -> Double {
        outputMode == .dop ? info.dopCarrierRate : Double(info.dsdSampleRate) / 32
    }

    func setOutputMode(_ mode: OutputMode) {
        outputMode = mode
        engine.outputMode = mode
        persist()
        // 播放中切换：从头重播当前曲目以应用新模式
        if state == .playing || state == .paused, let idx = currentIndex {
            play(at: idx)
        }
    }

    // MARK: 播放列表

    func addFiles() {
        let panel = NSOpenPanel()
        let dsfType = UTType(filenameExtension: "dsf") ?? .data
        let dffType = UTType(filenameExtension: "dff") ?? .data
        panel.allowedContentTypes = [dsfType, dffType]
        panel.allowsMultipleSelection = true
        panel.message = "选择 DSD 音频文件 (.dsf / .dff)，可多选"
        guard panel.runModal() == .OK else { return }
        add(urls: panel.urls)
    }

    func add(urls: [URL]) {
        // 展开文件夹：递归收集其中的 DSD 文件
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let f as URL in enumerator {
                        let ext = f.pathExtension.lowercased()
                        if ext == "dsf" || ext == "dff" { files.append(f) }
                    }
                }
            } else {
                let ext = url.pathExtension.lowercased()
                if ext == "dsf" || ext == "dff" { files.append(url) }
            }
        }
        // 按路径自然排序，保证专辑曲序（01、02…）
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        var added: [PlaylistItem] = []
        var failures: [String] = []
        for url in files {
            if playlist.contains(where: { $0.url == url }) { continue }
            do {
                let src = try DSDFile.open(url)
                added.append(PlaylistItem(url: url, info: src.info))
            } catch {
                failures.append(url.lastPathComponent)
            }
        }
        playlist.append(contentsOf: added)
        if !failures.isEmpty {
            statusMessage = "无法解析: \(failures.joined(separator: ", "))"
        }
        // 首个文件加入后自动加载（不自动播放）
        if currentIndex == nil, let first = added.first,
           let idx = playlist.firstIndex(of: first) {
            load(at: idx)
        }
        persist()
    }

    func remove(at offsets: IndexSet) {
        let removingCurrent = currentIndex.map { offsets.contains($0) } ?? false
        playlist.remove(atOffsets: offsets)
        if removingCurrent {
            engine.stop()
            state = .stopped
            currentIndex = nil
            position = 0
        } else if let cur = currentIndex {
            // 索引随删除前移
            let removed = offsets.filter { $0 < cur }.count
            currentIndex = cur - removed
        }
        persist()
    }

    // MARK: 播放控制

    private func load(at index: Int) {
        guard playlist.indices.contains(index) else { return }
        currentIndex = index
        persist()
        do {
            try engine.load(url: playlist[index].url)
            position = 0
            statusMessage = ""
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func play(at index: Int) {
        guard let dev = selectedDevice else {
            statusMessage = "请选择输出设备"
            return
        }
        load(at: index)
        guard currentInfo != nil, statusMessage.isEmpty else { return }
        do {
            try engine.play(device: dev.id)
            queueNextForGapless()
            updateNowPlaying()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// 优先无缝切换（同规格曲目保持音频链路不断），否则完整重开
    private func playOrSwitch(to index: Int) {
        guard playlist.indices.contains(index) else { return }
        if let src = try? DSDFile.open(playlist[index].url), engine.switchTrack(src) {
            currentIndex = index
            position = 0
            persist()
            queueNextForGapless()
            updateNowPlaying()
        } else {
            play(at: index)
        }
    }

    func togglePlay() {
        switch state {
        case .stopped, .finished:
            if currentIndex == nil, !playlist.isEmpty { load(at: 0) }
            guard let idx = currentIndex else { return }
            play(at: idx)
        case .playing:
            engine.pause()
        case .paused:
            guard let dev = selectedDevice else { return }
            do { try engine.play(device: dev.id) }
            catch { statusMessage = error.localizedDescription }
        case .idle:
            if !playlist.isEmpty { play(at: 0) }
        }
    }

    func next() {
        guard let idx = currentIndex, !playlist.isEmpty else { return }
        let target: Int
        switch playMode {
        case .shuffle:
            target = randomIndex(excluding: idx)
        default:
            target = (idx + 1) % playlist.count
        }
        playOrSwitch(to: target)
    }

    func previous() {
        guard let idx = currentIndex, !playlist.isEmpty else { return }
        // 播放超过 3 秒则回到本曲开头，否则上一首
        if position > 3, state == .playing || state == .paused {
            seek(to: 0)
            return
        }
        playOrSwitch(to: (idx - 1 + playlist.count) % playlist.count)
    }

    private func advanceAfterFinish() {
        guard let idx = currentIndex, !playlist.isEmpty else { return }
        switch playMode {
        case .loopOne:
            play(at: idx)
        case .shuffle:
            play(at: randomIndex(excluding: idx))
        case .loopAll:
            play(at: (idx + 1) % playlist.count)
        case .sequential:
            if idx + 1 < playlist.count { play(at: idx + 1) }
        }
    }

    private func randomIndex(excluding current: Int) -> Int {
        guard playlist.count > 1 else { return current }
        var i = current
        while i == current { i = Int.random(in: 0..<playlist.count) }
        return i
    }

    func seek(to seconds: Double) {
        engine.seek(toSeconds: seconds)
        position = seconds
    }

    /// 键盘左右方向键：快进/快退 5 秒
    func seekBy(_ delta: Double) {
        guard let info = currentInfo, state == .playing || state == .paused else { return }
        seek(to: max(0, min(info.durationSeconds, position + delta)))
    }
}

// MARK: - 主题

private let accent = Color(red: 0.93, green: 0.68, blue: 0.30)   // 琥珀金
private let bgTop = Color(red: 0.10, green: 0.09, blue: 0.13)
private let bgBottom = Color(red: 0.06, green: 0.06, blue: 0.09)
private let panelBg = Color.white.opacity(0.05)

// MARK: - 主界面

struct ContentView: View {
    @EnvironmentObject var model: PlayerModel
    @State private var selection = Set<PlaylistItem.ID>()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            nowPlaying
            transport
            Divider().overlay(Color.white.opacity(0.08))
            playlistView
            statusBar
        }
        .background(
            LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
        )
        // 隐藏按钮承载方向键快进退快捷键
        .background(
            HStack {
                Button("") { model.seekBy(-5) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { model.seekBy(5) }.keyboardShortcut(.rightArrow, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        )
        .preferredColorScheme(.dark)
        .frame(width: 720, height: 560)
    }

    // 顶栏: 标题 + 设备
    private var header: some View {
        HStack {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(accent)
            Text("DSD Player")
                .font(.headline)
            Text("DoP 位元直通")
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(accent.opacity(0.18))
                .foregroundStyle(accent)
                .clipShape(Capsule())
            Spacer()
            Picker("", selection: Binding(
                get: { model.outputMode },
                set: { model.setOutputMode($0) })) {
                Text("DoP 直通").tag(OutputMode.dop)
                Text("PCM 转换").tag(OutputMode.pcm)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 150)
            .help("DoP：位元直通给支持 DoP 的 DAC；PCM：转成高采样率 PCM，任意设备可用")
            Picker("", selection: $model.selectedDevice) {
                ForEach(model.devices) { dev in
                    Text(dev.name + (dev.isUSB ? " ⚡" : "")).tag(Optional(dev))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
            Button { model.refreshDevices() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新设备列表")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // 当前曲目信息
    private var nowPlaying: some View {
        VStack(spacing: 10) {
            Text(model.currentItem?.title ?? "未加载曲目")
                .font(.title3.weight(.semibold))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(model.currentItem == nil ? .secondary : .primary)

            if let info = model.currentInfo {
                HStack(spacing: 8) {
                    badge(info.formatName)
                    badge("DSD\(info.dsdMultiple)")
                    badge(String(format: "%.1f MHz", Double(info.dsdSampleRate) / 1e6))
                    badge("\(info.channelCount)ch")
                    badge(model.outputMode == .dop
                          ? "DoP \(Int(info.dopCarrierRate / 1000))kHz"
                          : "PCM \(Int(info.dsdSampleRate) / 32 / 1000)kHz",
                          highlight: true)
                }
            } else {
                Text("添加 .dsf / .dff 文件开始播放")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // 进度
            HStack(spacing: 10) {
                Text(formatTime(model.position))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { model.position },
                    set: { model.position = $0 }
                ), in: 0...max(1, model.currentInfo?.durationSeconds ?? 1),
                onEditingChanged: { editing in
                    if !editing { model.seek(to: model.position) }
                })
                .tint(accent)
                .disabled(model.state == .idle)
                Text(formatTime(model.currentInfo?.durationSeconds ?? 0))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // 传输控制
    private var transport: some View {
        HStack(spacing: 28) {
            Spacer()
            transportButton(model.playMode.icon, size: 18,
                            active: model.playMode != .sequential,
                            help: model.playMode.label) {
                model.playMode = model.playMode.next()
            }
            transportButton("backward.fill", size: 22, help: "上一首 (⌘←)") { model.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button { model.togglePlay() } label: {
                Image(systemName: model.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.borderless)
            .disabled(model.playlist.isEmpty)
            .keyboardShortcut(.space, modifiers: [])
            transportButton("forward.fill", size: 22, help: "下一首 (⌘→)") { model.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            // 占位平衡布局
            Image(systemName: model.playMode.icon)
                .font(.system(size: 18))
                .opacity(0)
                .disabled(true)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func transportButton(_ icon: String, size: CGFloat, active: Bool = false,
                                 help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundStyle(active ? accent : Color.primary.opacity(0.85))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.borderless)
        .disabled(model.playlist.isEmpty)
        .help(help)
    }

    // 播放列表
    private var playlistView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("播放列表")
                    .font(.subheadline.weight(.medium))
                Text("\(model.playlist.count) 首")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.addFiles() } label: {
                    Label("添加文件", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(accent)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)

            if model.playlist.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("拖入文件或文件夹，或点击「添加文件」")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(Array(model.playlist.enumerated()), id: \.element.id) { idx, item in
                        playlistRow(idx: idx, item: item)
                            .tag(item.id)
                            .contextMenu {
                                Button("移除") {
                                    if let i = model.playlist.firstIndex(of: item) {
                                        model.remove(at: IndexSet(integer: i))
                                    }
                                }
                            }
                    }
                    .onDelete { model.remove(at: $0) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.add(urls: [url]) }
                }
            }
            return true
        }
    }

    private func playlistRow(idx: Int, item: PlaylistItem) -> some View {
        HStack(spacing: 10) {
            if model.currentIndex == idx {
                Image(systemName: model.state == .playing ? "waveform" : "pause")
                    .font(.caption)
                    .foregroundStyle(accent)
                    .frame(width: 18)
            } else {
                Text("\(idx + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            Text(item.title)
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(model.currentIndex == idx ? accent : .primary)
            Spacer()
            badge("DSD\(item.info.dsdMultiple)", small: true)
            Text(formatTime(item.info.durationSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.play(at: idx) }
        .onTapGesture(count: 1) { selection = [item.id] }
    }

    private var statusBar: some View {
        HStack {
            if !model.statusMessage.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(model.statusMessage)
                    .foregroundStyle(.orange)
            } else if !model.deviceSupportsCarrier {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("该设备可能不支持所需的 DoP 载波采样率")
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(model.outputMode == .dop
                     ? "播放期间请勿调节系统音量（会破坏 DoP 位元），请用 DAC/功放调音量"
                     : "PCM 转换模式：可正常使用系统音量")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color.black.opacity(0.25))
    }

    private func badge(_ text: String, highlight: Bool = false, small: Bool = false) -> some View {
        Text(text)
            .font(small ? .caption2 : .caption)
            .padding(.horizontal, small ? 5 : 7).padding(.vertical, small ? 1 : 3)
            .background(highlight ? accent.opacity(0.22) : Color.white.opacity(0.08))
            .foregroundStyle(highlight ? accent : Color.primary.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private func formatTime(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

@main
struct DSDPlayerApp: App {
    @StateObject private var model = PlayerModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
