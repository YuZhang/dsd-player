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
    let skin: Int?          // 旧版本数据无此字段，解码为 nil 时用默认
    let showPlaylist: Bool? // 同上
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
    @Published var showPlaylist = true {
        didSet { persist() }
    }
    @Published var state: PlaybackEngine.State = .idle
    @Published var position: Double = 0
    @Published var meterL = 0.0   // VU 表电平 0...1（快攻慢放平滑后）
    @Published var meterR = 0.0
    @Published var statusMessage = ""

    let engine = PlaybackEngine()
    private var timer: Timer?
    private var meterTimer: Timer?
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
                               skin: skin.rawValue,
                               showPlaylist: showPlaylist)
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
        showPlaylist = saved.showPlaylist ?? true
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
        // VU 电平表独立 30Hz 刷新，保证动画流畅
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.meterTick() }
        }
        setupRemoteCommands()
        restore()
    }

    private func tick() {
        guard state == .playing || state == .paused else { return }
        position = engine.positionSeconds
        updateNowPlaying()
    }

    private func meterTick() {
        if state == .playing {
            let l = Double(engine.levelL.load(ordering: .relaxed)) / 1000
            let r = Double(engine.levelR.load(ordering: .relaxed)) / 1000
            // 快攻慢放（模拟表针动态）
            meterL = max(l, meterL * 0.91)
            meterR = max(r, meterR * 0.91)
        } else {
            meterL *= 0.94
            meterR *= 0.92
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

    /// 需要提示用户的信息（设备不兼容 / 错误），nil 表示一切正常
    var warningText: String? {
        if !statusMessage.isEmpty { return statusMessage }
        if !deviceSupportsCarrier {
            return "This device may not support the required DoP carrier rate"
        }
        return nil
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
                isDark: false,
                physicalButtons: true,
                dotGrid: false)
        case .terminal:
            // 绿磷光终端
            return Theme(
                bgTop: Color(red: 0.04, green: 0.07, blue: 0.05),
                bgBottom: Color(red: 0.02, green: 0.04, blue: 0.03),
                accent: Color(red: 0.24, green: 0.94, blue: 0.45),
                badgeBg: Color(red: 0.24, green: 0.94, blue: 0.45).opacity(0.12),
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
    @State private var holeFreeRects: [CGRect] = []

    private var theme: Theme { model.skin.theme }

    var body: some View {
        VStack(spacing: 0) {
            // 上部面板：正文正常布局，不做任何手动补偿
            VStack(spacing: 0) {
                header
                nowPlaying
                transport
            }
            .background(faceplateBackground)
            if model.showPlaylist {
                Divider().overlay(theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.12))
                playlistView
                    .background(theme.bgBottom)   // 不透明盖住冲孔
            }
        }
        .coordinateSpace(name: "root")
        .onPreferenceChange(HoleFreeRectKey.self) { holeFreeRects = $0 }
        // 列表展开时填满窗口（多余高度由列表区域吸收）；收起时内容自适应使窗口收缩
        .frame(maxHeight: model.showPlaylist ? .infinity : nil, alignment: .top)
        // 背景负责延伸进标题栏（仅背景忽略顶部安全区，正文保持正常布局）；
        // 背景不参与内容尺寸计算，窗口保持固定不可拖大
        .background {
            Group {
                if theme.dotGrid {
                    holeCanvas
                } else {
                    theme.bgTop   // 与面板同一个颜色来源
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
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
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)   // 去掉标题栏系统材质
        .frame(width: 720)
        .background(WindowConfigurator())   // 标题栏完全透明
    }

    /// 冲孔画布：面板色 + 冲孔铺满整个窗口（含标题栏），播放列表区域由列表自己的不透明底色盖住
    private var holeCanvas: some View {
        GeometryReader { geo in
            // 画布与 root 坐标系的偏移（画布顶在窗口顶，内容顶在安全区下）
            let offsetY = geo.frame(in: .named("root")).minY
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.bgTop))
                // 只在紧凑布局（收起播放列表）时绘制冲孔
                guard !model.showPlaylist else { return }
                // 冲孔：深色孔 + 下缘高光；水平对称；避开控件与红绿灯区域
                let step: CGFloat = 15
                let d: CGFloat = 12
                let margin: CGFloat = 7
                var zones = holeFreeRects.map {
                    $0.insetBy(dx: -margin, dy: -margin).offsetBy(dx: 0, dy: -offsetY)
                }
                zones.append(CGRect(x: 0, y: 0, width: 78, height: 34))   // 红绿灯按钮区域
                // 列数按“边缘至少留 step”计算，起始位置使左右留白相等
                let count = Int((size.width - 2 * step + (step - d)) / step)
                let startX = (size.width - (step * CGFloat(count - 1) + d)) / 2
                var y: CGFloat = step
                // 底部保留 step 余量：只画完整可见的行（含下缘高光）
                while y + d + 3.5 <= size.height - step {
                    var x: CGFloat = startX
                    for _ in 0..<count {
                        let hole = CGRect(x: x, y: y, width: d, height: d)
                        if !zones.contains(where: { $0.intersects(hole) }) {
                            ctx.fill(Path(ellipseIn: hole.offsetBy(dx: 0, dy: 3.5)),
                                     with: .color(.white.opacity(0.55)))
                            ctx.fill(Path(ellipseIn: hole),
                                     with: .color(.black.opacity(0.18)))
                        }
                        x += step
                    }
                    y += step
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var faceplateBackground: some View {
        // 纯色面板：与标题栏（外层背景 bgTop）严格同源同色
        theme.bgTop
    }

    // 顶栏: 标题 + 输出模式 + 设备 + 皮肤
    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.accent)
                Text("DSD Player")
                    .font(.headline)
            }
            .holeFreeZone()
            .padding(.leading, 64)   // 避开红绿灯按钮
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
            .holeFreeZone()
            // 告警图标：固定占位，有告警时显示，悬停查看详情（不影响其他控件位置）
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .opacity(model.warningText != nil ? 1 : 0)
                .allowsHitTesting(model.warningText != nil)
                .help(model.warningText ?? "")
                .frame(width: 18)
                .holeFreeZone()
            Picker("", selection: $model.selectedDevice) {
                ForEach(model.devices) { dev in
                    Text(dev.name + (dev.isUSB ? " ⚡" : "")).tag(Optional(dev))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
            .holeFreeZone()
            HStack(spacing: 12) {
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
                    Image(systemName: "tshirt")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)
                .help("Skin")
            }
            .holeFreeZone()
        }
        .padding(.horizontal, 16)
        .padding(.top, 3)   // 与红绿灯同处标题栏一行
        .padding(.bottom, 12)
    }

    // 当前曲目信息
    private var nowPlaying: some View {
        VStack(spacing: 10) {
            MarqueeText(text: model.currentItem?.title ?? "No Track Loaded",
                        font: .title3.weight(.semibold))
                .foregroundStyle(model.currentItem == nil ? .secondary : .primary)
                .frame(maxWidth: 480)   // 固定宽度，超出部分滚动显示
                .holeFreeZone()

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
                .holeFreeZone()
            } else {
                Text("Add .dsf / .dff files to start playing")
                    .font(.caption).foregroundStyle(.secondary)
                    .holeFreeZone()
            }

            // 进度（收窄，两侧露出冲孔）
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
            .holeFreeZone()
            .padding(.horizontal, 56)   // 避让区只含内容；实测补偿后两侧恰好露出 3 个冲孔

            // VU 电平表（左声道 ← 指示灯 → 右声道，收窄）
            VUMeter(left: model.meterL, right: model.meterR, theme: theme,
                    isPlaying: model.state == .playing)
                .padding(.top, 2)
                .holeFreeZone()
                .padding(.horizontal, 56)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // 传输控制
    private var transport: some View {
        HStack {
            Spacer()
            HStack(spacing: 28) {
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
                // 列表显隐
                transportButton("list.bullet", size: 18,
                                active: model.showPlaylist,
                                help: model.showPlaylist ? "Hide Playlist" : "Show Playlist") {
                    model.showPlaylist.toggle()
                }
            }
            .holeFreeZone()
            Spacer()
        }
        .padding(.top, 6)
        .padding(.bottom, 30)   // 播放按钮下方 1 行冲孔 + 正常边距
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
                .frame(height: 400)   // 固定高度：恰好 10 首（实测行距 39.7pt）
            }
        }
        .frame(maxWidth: .infinity)
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
        .frame(height: 30)   // 固定行高，列表高度 = 10 行 × 32pt
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.play(at: idx) }
        .onTapGesture(count: 1) { selection = [item.id] }
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

// MARK: - 冲孔避让区域

/// 收集面板控件的 frame，冲孔绘制时避开这些区域（faceplate 坐标系）
struct HoleFreeRectKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
    }
}

extension View {
    /// 声明该控件周围不绘制冲孔纹理
    func holeFreeZone() -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: HoleFreeRectKey.self,
                                   value: [geo.frame(in: .named("root"))])
        })
    }
}

// MARK: - 窗口配置

/// 让标题栏完全透明且内容铺满整个窗口（含标题栏区域），面板任意处可拖动。
/// SwiftUI 会在视图更新时重置窗口属性，所以在 updateNSView 里反复应用。
private struct WindowConfigurator: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applySettings()
        }
        func applySettings() {
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)   // 内容区扩展到标题栏
            window.styleMask.remove(.resizable)             // 禁止用户调整窗口大小
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true       // 面板空白处即可拖动窗口
            // 标题栏装饰视图会画底部分隔线，隐藏它（红绿灯按钮在别的视图里，不受影响）
            if let root = window.contentView?.superview {
                for sub in root.subviews {
                    for inner in sub.subviews {
                        if String(describing: type(of: inner)).contains("DecorationView") {
                            inner.isHidden = true
                        }
                    }
                }
            }
        }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ nsView: View, context: Context) {
        nsView.applySettings()   // 每次 SwiftUI 更新都重新应用，防止被重置
    }
}

// MARK: - 滚动文本（超长歌名往返滚动）

struct MarqueeText: View {
    let text: String
    var font: Font = .title3.weight(.semibold)

    @State private var startDate = Date()

    /// 用 NSFont 直接测量文本宽度（title3 字号的近似值，对滚动判定足够精确）
    private var textWidth: CGFloat {
        let size = NSFont.preferredFont(forTextStyle: .title3).pointSize
        let nsFont = NSFont.systemFont(ofSize: size, weight: .semibold)
        return (text as NSString).size(withAttributes: [.font: nsFont]).width
    }

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth - geo.size.width
            if overflow > 0 {
                // 时间轴驱动：左停 1.5s → 滚到底 → 停 1.5s → 滚回，循环
                TimelineView(.periodic(from: .now, by: 1.0 / 30)) { context in
                    Text(text)
                        .font(font)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .offset(x: -scrollDistance(at: context.date, overflow: overflow))
                }
            } else {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)   // 短文本居中
            }
        }
        .frame(height: 26)
        .clipped()
        .onChange(of: text) { startDate = Date() }
    }

    private func scrollDistance(at date: Date, overflow: CGFloat) -> CGFloat {
        let pause = 1.5
        let move = Double(overflow) / 40   // 40pt/s
        let cycle = (pause + move) * 2
        var t = date.timeIntervalSince(startDate).truncatingRemainder(dividingBy: cycle)
        if t < pause { return 0 }
        t -= pause
        if t < move { return CGFloat(t / move) * overflow }
        t -= move
        if t < pause { return overflow }
        t -= pause
        return overflow - CGFloat(min(t / move, 1)) * overflow
    }
}

// MARK: - VU 电平表

/// 左声道 ← 中央指示灯 → 右声道，电平从中间向两侧增长
struct VUMeter: View {
    let left: Double    // 0...1
    let right: Double
    let theme: Theme
    var isPlaying: Bool = false
    private let segments = 28   // 每侧段数（组件总宽不变）

    var body: some View {
        HStack(spacing: 6) {
            // 左声道：从中间向左增长
            HStack(spacing: 1.5) {
                ForEach(0..<segments, id: \.self) { i in
                    let fromCenter = Double(segments - 1 - i) / Double(segments)  // 0=靠中间
                    segment(lit: fromCenter < norm(left), pos: fromCenter)
                }
            }
            // 中央指示灯：播放时亮起
            Circle()
                .fill(isPlaying ? theme.accent : theme.badgeBg)
                .frame(width: 13, height: 13)
                .shadow(color: isPlaying ? theme.accent.opacity(0.8) : .clear,
                        radius: 5)
            // 右声道：从中间向右增长
            HStack(spacing: 1.5) {
                ForEach(0..<segments, id: \.self) { i in
                    let fromCenter = Double(i) / Double(segments)
                    segment(lit: fromCenter < norm(right), pos: fromCenter)
                }
            }
        }
        .frame(height: 13)
    }

    /// 线性 RMS 幅度 → 对数尺度：-60dB 映射到 0，0dB 映射到 1
    private func norm(_ level: Double) -> Double {
        let db = 20 * log10(max(level, 1e-6))
        return max(0, (db + 60) / 60)
    }

    private func segment(lit: Bool, pos: Double) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(lit ? segmentColor(pos) : theme.badgeBg)
            .frame(maxWidth: .infinity)
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
        .windowStyle(.hiddenTitleBar)   // 内容延伸到标题栏，面板浑然一体
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
