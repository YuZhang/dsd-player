import SwiftUI
import AppKit
import MediaPlayer
import UniformTypeIdentifiers

// MARK: - 持久化状态（internal 以便单元测试）

struct SavedState: Codable, Equatable {
    let paths: [String]
    let currentIndex: Int?
    let playMode: Int
    let outputMode: Int
    let skin: Int?   // 旧版本数据无此字段，解码为 nil 时用默认
}

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
        case .sequential: return "Sequential"
        case .loopAll: return "Loop All"
        case .loopOne: return "Repeat One"
        case .shuffle: return "Shuffle"
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
    @Published var skin: Skin = .dark {
        didSet { persist() }
    }
    @Published var state: PlaybackEngine.State = .idle
    @Published var position: Double = 0
    @Published var meterL = 0.0   // VU 表电平 0...1（快攻慢放平滑后）
    @Published var meterR = 0.0
    @Published var statusMessage = ""

    let engine = PlaybackEngine()
    private var timer: Timer?
    private var queuedNextIndex: Int?   // 无缝预排的下一首

    // MARK: 持久化

    private let persistKey = "DSDPlayer.savedState"
    private var isRestoring = false

    private func persist() {
        guard !isRestoring else { return }
        let saved = SavedState(paths: playlist.map { $0.url.path },
                               currentIndex: currentIndex,
                               playMode: playMode.rawValue,
                               outputMode: outputMode.rawValue,
                               skin: skin.rawValue)
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
        skin = Skin(rawValue: saved.skin ?? 0) ?? .dark
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
            statusMessage = "\(missing) file(s) moved or deleted, not restored"
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
        guard state == .playing || state == .paused else {
            meterL *= 0.8; meterR *= 0.8   // 停止时电平衰减归零
            return
        }
        position = engine.positionSeconds
        updateNowPlaying()
        // VU 表：读取引擎电平，快攻慢放
        let l = Double(engine.levelL.load(ordering: .relaxed)) / 1000
        let r = Double(engine.levelR.load(ordering: .relaxed)) / 1000
        if state == .playing {
            meterL = max(l, meterL * 0.7)
            meterR = max(r, meterR * 0.7)
        } else {
            meterL *= 0.8; meterR *= 0.8
        }
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
        panel.message = "Choose DSD audio files (.dsf / .dff) — multiple selection allowed"
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
            statusMessage = "Cannot parse: \(failures.joined(separator: ", "))"
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
            statusMessage = "Select an output device"
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

// MARK: - 主题 / 皮肤

struct Theme {
    let bgTop: Color
    let bgBottom: Color
    let accent: Color
    let badgeBg: Color
    let statusBarBg: Color
    let isDark: Bool
    let physicalButtons: Bool   // 拟物按钮（圆形凸起 + 阴影）
    let dotGrid: Bool           // 面板点阵纹理（博朗风格）
}

enum Skin: Int, CaseIterable, Identifiable {
    case dark
    case braun
    case terminal

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .dark: return "Dark (Default)"
        case .braun: return "Braun Retro"
        case .terminal: return "Terminal Green"
        }
    }

    var theme: Theme {
        switch self {
        case .dark:
            return Theme(
                bgTop: Color(red: 0.10, green: 0.09, blue: 0.13),
                bgBottom: Color(red: 0.06, green: 0.06, blue: 0.09),
                accent: Color(red: 0.93, green: 0.68, blue: 0.30),
                badgeBg: Color.white.opacity(0.08),
                statusBarBg: Color.black.opacity(0.25),
                isDark: true,
                physicalButtons: false,
                dotGrid: false)
        case .braun:
            // 博朗复古设备：暖米白机身、橙红按键、拟物圆形按钮、面板点阵
            return Theme(
                bgTop: Color(red: 0.937, green: 0.929, blue: 0.902),
                bgBottom: Color(red: 0.878, green: 0.867, blue: 0.831),
                accent: Color(red: 0.875, green: 0.33, blue: 0.12),
                badgeBg: Color.black.opacity(0.07),
                statusBarBg: Color.black.opacity(0.06),
                isDark: false,
                physicalButtons: true,
                dotGrid: true)
        case .terminal:
            // 绿磷光终端
            return Theme(
                bgTop: Color(red: 0.04, green: 0.07, blue: 0.05),
                bgBottom: Color(red: 0.02, green: 0.04, blue: 0.03),
                accent: Color(red: 0.24, green: 0.94, blue: 0.45),
                badgeBg: Color(red: 0.24, green: 0.94, blue: 0.45).opacity(0.12),
                statusBarBg: Color.black.opacity(0.3),
                isDark: true,
                physicalButtons: false,
                dotGrid: false)
        }
    }
}

// MARK: - 主界面

struct ContentView: View {
    @EnvironmentObject var model: PlayerModel
    @State private var selection = Set<PlaylistItem.ID>()

    private var theme: Theme { model.skin.theme }

    var body: some View {
        VStack(spacing: 0) {
            // 上部面板（博朗皮肤带细点阵纹理）
            VStack(spacing: 0) {
                header
                Divider().overlay(theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.12))
                nowPlaying
                transport
            }
            .background(faceplateBackground)
            Divider().overlay(theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.12))
            playlistView
            statusBar
        }
        .background(theme.bgBottom)
        // 隐藏按钮承载方向键快进退快捷键
        .background(
            HStack {
                Button("") { model.seekBy(-5) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { model.seekBy(5) }.keyboardShortcut(.rightArrow, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        )
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .frame(width: 720, height: 560)
    }

    private var faceplateBackground: some View {
        ZStack {
            LinearGradient(colors: [theme.bgTop, theme.bgBottom],
                           startPoint: .top, endPoint: .bottom)
            if theme.dotGrid { dotGridTexture }
        }
    }

    /// 博朗风格细点阵纹理
    private var dotGridTexture: some View {
        Canvas { ctx, size in
            let step: CGFloat = 13
            var y: CGFloat = step
            while y < size.height {
                var x: CGFloat = step
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.3, height: 1.3)),
                             with: .color(.black.opacity(0.045)))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }

    // 顶栏: 标题 + 输出模式 + 设备 + 皮肤
    private var header: some View {
        HStack {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(theme.accent)
            Text("DSD Player")
                .font(.headline)
            Text("DoP Bit-Perfect")
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(theme.accent.opacity(0.18))
                .foregroundStyle(theme.accent)
                .clipShape(Capsule())
            Spacer()
            Picker("", selection: Binding(
                get: { model.outputMode },
                set: { model.setOutputMode($0) })) {
                Text("DoP").tag(OutputMode.dop)
                Text("PCM").tag(OutputMode.pcm)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 130)
            .help("DoP: bit-perfect to DoP-capable DACs; PCM: convert to hi-res PCM, works on any device")
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
            .help("Refresh device list")
            Menu {
                ForEach(Skin.allCases) { skin in
                    Button {
                        model.skin = skin
                    } label: {
                        if skin == model.skin {
                            Label(skin.name, systemImage: "checkmark")
                        } else {
                            Text(skin.name)
                        }
                    }
                }
            } label: {
                Image(systemName: "paintbrush")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help("Skin")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // 当前曲目信息
    private var nowPlaying: some View {
        VStack(spacing: 10) {
            Text(model.currentItem?.title ?? "No Track Loaded")
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
                Text("Add .dsf / .dff files to start playing")
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
                .tint(theme.accent)
                .disabled(model.state == .idle)
                Text(formatTime(model.currentInfo?.durationSeconds ?? 0))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            // VU 电平表（立体声分段条）
            VUMeter(left: model.meterL, right: model.meterR, theme: theme)
                .padding(.top, 2)
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
            transportButton("backward.fill", size: 22, help: "Previous (⌘←)") { model.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button { model.togglePlay() } label: {
                if theme.physicalButtons {
                    // 拟物大圆钮（博朗风格）
                    Image(systemName: model.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(
                            Circle()
                                .fill(theme.accent)
                                .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                        )
                } else {
                    Image(systemName: model.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(theme.accent)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.playlist.isEmpty)
            .keyboardShortcut(.space, modifiers: [])
            transportButton("forward.fill", size: 22, help: "Next (⌘→)") { model.next() }
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
                .font(.system(size: size, weight: theme.physicalButtons ? .semibold : .regular))
                .foregroundStyle(active ? theme.accent : Color.primary.opacity(0.85))
                .frame(width: 36, height: 36)
                .background {
                    if theme.physicalButtons {
                        Circle()
                            .fill(theme.bgTop)
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1.5)
                            .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(model.playlist.isEmpty)
        .help(help)
    }

    // 播放列表
    private var playlistView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Playlist")
                    .font(.subheadline.weight(.medium))
                Text("\(model.playlist.count) tracks")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.addFiles() } label: {
                    Label("Add Files", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.accent)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)

            if model.playlist.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("Drop files or folders here, or click Add Files")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(Array(model.playlist.enumerated()), id: \.element.id) { idx, item in
                        playlistRow(idx: idx, item: item)
                            .tag(item.id)
                            .contextMenu {
                                Button("Remove") {
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
                    .foregroundStyle(theme.accent)
                    .frame(width: 18)
            } else {
                Text("\(idx + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            Text(item.title)
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(model.currentIndex == idx ? theme.accent : .primary)
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
                Text("This device may not support the required DoP carrier rate")
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(model.outputMode == .dop
                     ? "DoP is bit-perfect: don't change system volume while playing — use DAC/amp volume"
                     : "PCM mode: system volume works normally")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(theme.statusBarBg)
    }

    private func badge(_ text: String, highlight: Bool = false, small: Bool = false) -> some View {
        Text(text)
            .font(small ? .caption2 : .caption)
            .padding(.horizontal, small ? 5 : 7).padding(.vertical, small ? 1 : 3)
            .background(highlight ? theme.accent.opacity(0.22) : theme.badgeBg)
            .foregroundStyle(highlight ? theme.accent : Color.primary.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - VU 电平表

struct VUMeter: View {
    let left: Double    // 0...1
    let right: Double
    let theme: Theme
    private let segments = 32

    var body: some View {
        VStack(spacing: 3) {
            row(left)
            row(right)
        }
    }

    private func row(_ level: Double) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                let pos = Double(i) / Double(segments)
                RoundedRectangle(cornerRadius: 1)
                    .fill(pos < level ? segmentColor(pos) : theme.badgeBg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 5)
            }
        }
    }

    private func segmentColor(_ pos: Double) -> Color {
        if pos > 0.9 { return .red.opacity(0.9) }   // 峰值区红色警示
        return theme.accent
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
