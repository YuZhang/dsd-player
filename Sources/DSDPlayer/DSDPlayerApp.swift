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
    let pcmRateBoost: Int?  // PCM 输出采样率提升档（0=/32, 1=×2, 2=×4）
    let customAccent: String?   // Dark 皮肤自定义强调色（hex），nil = 默认
    let customBg: String?       // Dark 皮肤自定义背景色（hex）
    let customBgOpacity: Double?   // 背景透明度 0...1，nil = 不透明
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
    let isoTrackIndex: Int?   // 非 nil：SACD ISO 内的第 N 首（url 指向 ISO 文件）
    let title: String

    init(url: URL, info: DSDInfo) {
        self.url = url
        self.info = info
        self.isoTrackIndex = nil
        self.title = url.deletingPathExtension().lastPathComponent
    }

    init(isoURL: URL, info: DSDInfo, trackIndex: Int, title: String) {
        self.url = isoURL
        self.info = info
        self.isoTrackIndex = trackIndex
        self.title = title
    }
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
    /// PCM 输出采样率提升档：0 = DSD率/32，1 = ×2，2 = ×4
    @Published var pcmRateBoost = 0 {
        didSet { persist() }
    }
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
    private var playingDeviceUID: String?   // 正在播放设备的持久 UID（检测播放设备被拔出）
    nonisolated(unsafe) private var isoCache: [String: SacdISO] = [:]   // SACD ISO 解析缓存（按路径，手动加锁）
    private let isoCacheLock = NSLock()
    /// 引擎操作串行队列：打开文件/建 AudioUnit/预缓冲等耗时操作在此执行，避免卡主线程
    private let engineQueue = DispatchQueue(label: "local.dsdplayer.engine")
    /// 正在执行的加载任务计数（主线程维护）；playGeneration 防止快速连点时旧任务覆盖新状态
    private var switchingCount = 0
    private var playGeneration = 0

    // MARK: Dark 皮肤自定义颜色（仅 Dark 皮肤生效）
    @Published var customAccentHex: String?
    @Published var customBgHex: String?
    @Published var customBgOpacity: Double?   // 背景透明度 0...1，nil = 不透明

    /// 应用自定义强调色（实时预览）
    func setCustomAccent(_ color: Color) {
        customAccentHex = color.hexString
        persist()
    }
    /// 应用自定义背景色（实时预览）
    func setCustomBg(_ color: Color) {
        customBgHex = color.hexString
        persist()
    }
    /// 恢复 Dark 默认配色（金色 + #121212 + 不透明）
    func resetCustomColors() {
        customAccentHex = nil
        customBgHex = nil
        customBgOpacity = nil
        persist()
    }
    /// 设置背景透明度（0...1，实时预览）
    func setCustomBgOpacity(_ value: Double) {
        customBgOpacity = value
        persist()
    }

    /// 生效主题：Dark 皮肤叠加自定义颜色，其他皮肤用固定定义
    var effectiveTheme: Theme {
        var t = skin.theme
        guard skin == .dark else { return t }
        if let hex = customAccentHex, let c = Color(hex: hex) {
            t = Theme(bgTop: t.bgTop, bgBottom: t.bgBottom, accent: c, badgeBg: t.badgeBg,
                      isDark: t.isDark, physicalButtons: t.physicalButtons, dotGrid: t.dotGrid,
                      crtGlow: t.crtGlow, proLook: t.proLook)
        }
        if let hex = customBgHex, let c = Color(hex: hex) {
            // 浅色背景：切换为浅色模式（主文字变深），徽标底色反转
            let light = luminance(c) > 0.45
            let bg = c.opacity(customBgOpacity ?? 1)
            t = Theme(bgTop: bg, bgBottom: bg, accent: t.accent,
                      badgeBg: light ? Color.black.opacity(0.07) : Color.white.opacity(0.08),
                      isDark: !light, physicalButtons: t.physicalButtons, dotGrid: t.dotGrid,
                      crtGlow: t.crtGlow, proLook: t.proLook)
        } else if let op = customBgOpacity, op < 1 {
            // 仅调透明度：默认背景色加透明
            let bg = t.bgTop.opacity(op)
            t = Theme(bgTop: bg, bgBottom: bg, accent: t.accent, badgeBg: t.badgeBg,
                      isDark: t.isDark, physicalButtons: t.physicalButtons, dotGrid: t.dotGrid,
                      crtGlow: t.crtGlow, proLook: t.proLook)
        }
        return t
    }

    /// 打开列表项对应的数据源：普通文件走 DSDFile，ISO 曲目走 SacdTrackSource。
    /// nonisolated：可能被引擎队列调用，内部已用锁保护缓存
    nonisolated func openSource(for item: PlaylistItem) throws -> DSDSource {
        if let trackIdx = item.isoTrackIndex {
            let path = item.url.path
            isoCacheLock.lock()
            let cached = isoCache[path]
            isoCacheLock.unlock()
            let iso: SacdISO
            if let cached {
                iso = cached
            } else {
                iso = try SacdISO(url: item.url)
                isoCacheLock.lock()
                isoCache[path] = iso
                isoCacheLock.unlock()
            }
            return try iso.makeTrackSource(iso.album.tracks[trackIdx])
        }
        return try DSDFile.open(item.url)
    }

    // MARK: 持久化

    private let persistKey = "DSDPlayer.savedState"
    private var isRestoring = false

    private func persist() {
        guard !isRestoring else { return }
        let saved = SavedState(paths: playlist.map { $0.url.path + ($0.isoTrackIndex.map { "#track=\($0)" } ?? "") },
                               currentIndex: currentIndex,
                               playMode: playMode.rawValue,
                               outputMode: outputMode.rawValue,
                               skin: skin.rawValue,
                               showPlaylist: showPlaylist,
                               pcmRateBoost: pcmRateBoost,
                               customAccent: customAccentHex,
                               customBg: customBgHex,
                               customBgOpacity: customBgOpacity)
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
        pcmRateBoost = saved.pcmRateBoost ?? 0
        engine.pcmRateBoost = pcmRateBoost
        customAccentHex = saved.customAccent
        customBgHex = saved.customBg
        customBgOpacity = saved.customBgOpacity
        var items: [PlaylistItem] = []
        var missing = 0
        for path in saved.paths {
            // ISO 曲目条目："iso路径#track=N"
            if let range = path.range(of: "#track="), let idx = Int(path[range.upperBound...]) {
                let isoPath = String(path[..<range.lowerBound])
                guard FileManager.default.fileExists(atPath: isoPath) else { missing += 1; continue }
                do {
                    let iso: SacdISO
                    if let cached = isoCache[isoPath] { iso = cached }
                    else { iso = try SacdISO(url: URL(fileURLWithPath: isoPath)); isoCache[isoPath] = iso }
                    let t = iso.album.tracks[idx]
                    let info = DSDInfo(formatName: "SACD", dsdSampleRate: 2_822_400,
                                       channelCount: iso.album.channelCount,
                                       totalSamplesPerChannel: UInt64(t.durationSeconds * 75 * 4704 * 8))
                    items.append(PlaylistItem(isoURL: URL(fileURLWithPath: isoPath), info: info,
                                              trackIndex: idx,
                                              title: t.title.isEmpty ? "Track \(t.index + 1)" : t.title))
                } catch { missing += 1 }
                continue
            }
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
            select(at: idx)
        }
    }

    var currentItem: PlaylistItem? {
        guard let i = currentIndex, playlist.indices.contains(i) else { return nil }
        return playlist[i]
    }
    var currentInfo: DSDInfo? { currentItem?.info }

    init() {
        refreshDevices()
        engine.pcmRateBoost = pcmRateBoost
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
            self.position = 0
            self.refreshCover()
            self.persist()
            self.updateNowPlaying()
            self.queueNextForGapless()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // VU 电平表独立 30Hz 刷新，保证动画流畅
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.meterTick() }
        }
        setupRemoteCommands()
        restore()
        applyLaunchDevicePolicy()
        // 设备列表变更监听：拔插 / 睡眠唤醒后系统会重枚举设备（id 变化），
        // 按持久 UID 重新匹配，避免绑定到失效的旧 id 导致无法播放
        AudioDeviceManager.installDeviceChangeListener { [weak self] in
            Task { @MainActor in self?.handleDeviceChange() }
        }
    }

    /// 设备列表变化：同 UID 设备换新 id 则透明更新；正在播放的设备消失则停止
    private func handleDeviceChange() {
        let prevUID = selectedDevice?.uid
        devices = AudioDeviceManager.outputDevices()
        if let uid = prevUID, let match = devices.first(where: { $0.uid == uid }) {
            selectedDevice = match   // 同一物理设备，id 可能已变
        } else if let cur = selectedDevice, devices.contains(cur) {
            // 保持不变
        } else if let def = AudioDeviceManager.defaultOutputDevice(),
                  let dev = devices.first(where: { $0.id == def }) {
            selectedDevice = dev
        } else {
            selectedDevice = devices.first(where: { $0.isUSB }) ?? devices.first
        }
        // 正在播放/暂停的设备被拔出：停止并提示
        if let puid = playingDeviceUID, state == .playing || state == .paused,
           !devices.contains(where: { $0.uid == puid }) {
            engineQueue.async { self.engine.stop() }
            state = .stopped
            playingDeviceUID = nil
            statusMessage = "Output device disconnected"
        }
    }

    /// 启动设备策略：有 USB DAC 时选它并用 DoP 位元直通，否则用 PCM 模式（任意设备可用）
    private func applyLaunchDevicePolicy() {
        if let usb = devices.first(where: { $0.isUSB }) {
            selectedDevice = usb
            setOutputMode(.dop)
        } else {
            setOutputMode(.pcm)
        }
    }

    private func tick() {
        // 切换中也保持刷新：进度显示乐观值（0），避免冻结在上首歌的位置
        guard state == .playing || state == .paused || switchingCount > 0 else { return }
        if switchingCount == 0 {
            position = engine.positionSeconds
        }
        updateNowPlaying()
    }

    private func meterTick() {
        if state == .playing || switchingCount > 0 {
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

    /// 按当前播放模式预排下一首，交给引擎在同规格时无缝衔接。
    /// 打开文件放到引擎队列异步做，避免 ISO 解析等阻塞主线程
    private func queueNextForGapless() {
        guard let idx = currentIndex, !playlist.isEmpty else {
            queuedNextIndex = nil
            engineQueue.async { self.engine.setNext(nil) }
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
        guard let ni = nextIdx else {
            engineQueue.async { self.engine.setNext(nil) }
            return
        }
        let item = playlist[ni]
        engineQueue.async {
            self.engine.setNext(try? self.openSource(for: item))
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
        // PCM 模式不独占设备：CoreAudio 会自动重采样到设备原生率，任意 PCM 率均可播放；
        // 只有 DoP 位元直通要求设备严格支持载波率
        guard outputMode == .dop else { return true }
        return dev.supports(rate: info.dopCarrierRate)
    }

    /// 计算设备实际可用的 PCM 提升档：用户偏好超出设备能力时逐档降低
    nonisolated static func supportedBoost(baseRate: Int, preferred: Int, device: OutputDevice) -> Int {
        var b = max(0, min(2, preferred))
        while b > 0, !device.supports(rate: Double(baseRate * (1 << b))) { b -= 1 }
        return b
    }

    /// 需要提示用户的信息（设备不兼容 / 错误），nil 表示一切正常
    var warningText: String? {
        if !statusMessage.isEmpty { return statusMessage }
        if !deviceSupportsCarrier {
            return outputMode == .dop
                ? "This device may not support the required DoP carrier rate"
                : "This device may not support the selected PCM output rate"
        }
        return nil
    }

    func activeOutputRate(for info: DSDInfo) -> Double {
        outputMode == .dop ? info.dopCarrierRate : pcmOutputRate(for: info)
    }

    /// PCM 输出采样率（44.1k 家族的整数倍）
    func pcmOutputRate(for info: DSDInfo) -> Double {
        Double(info.dsdSampleRate) / 32 * Double(1 << max(0, min(2, pcmRateBoost)))
    }

    /// 切换 PCM 输出采样率：播放中保持位置续播
    func setPcmRateBoost(_ boost: Int) {
        pcmRateBoost = max(0, min(2, boost))
        rebuildOutputChain()
    }

    func setOutputMode(_ mode: OutputMode) {
        outputMode = mode
        persist()
        rebuildOutputChain()
    }

    /// 播放/暂停中重建输出链（切换 DoP/PCM 或 PCM 采样率）：引擎队列中保持位置续播
    private func rebuildOutputChain() {
        guard state == .playing || state == .paused, let idx = currentIndex,
              playlist.indices.contains(idx), let dev = selectedDevice else { return }
        let wasPaused = state == .paused
        let pos = engine.positionSeconds
        playGeneration &+= 1
        let gen = playGeneration
        switchingCount += 1
        position = pos   // 乐观更新：切换瞬间进度条即到位
        let item = playlist[idx]
        let devID = dev.id, devUID = dev.uid
        let mode = outputMode, boost = pcmRateBoost
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.engine.outputMode = mode
            self.engine.pcmRateBoost = Self.supportedBoost(
                baseRate: Int(item.info.dsdSampleRate) / 32,
                preferred: boost, device: dev)
            var error: Error?
            do {
                let src = try self.openSource(for: item)
                try self.engine.load(source: src)
                try self.engine.play(device: devID)
                self.engine.seek(toSeconds: pos)
                if wasPaused { self.engine.pause() }
            } catch let e {
                error = e
            }
            DispatchQueue.main.async {
                self.switchingCount -= 1
                guard self.playGeneration == gen else { return }
                if let error {
                    self.statusMessage = error.localizedDescription
                    return
                }
                self.position = pos
                self.statusMessage = ""
                self.playingDeviceUID = devUID
                self.queueNextForGapless()
                self.updateNowPlaying()
            }
        }
    }

    // MARK: 播放列表

    func addFiles() {
        let panel = NSOpenPanel()
        let dsfType = UTType(filenameExtension: "dsf") ?? .data
        let dffType = UTType(filenameExtension: "dff") ?? .data
        let isoType = UTType(filenameExtension: "iso") ?? .data
        panel.allowedContentTypes = [dsfType, dffType, isoType]
        panel.allowsMultipleSelection = true
        panel.message = "Choose DSD audio files (.dsf / .dff) or SACD ISO — multiple selection allowed"
        guard panel.runModal() == .OK else { return }
        add(urls: panel.urls)
    }

    func add(urls: [URL]) {
        // 展开文件夹：递归收集其中的 DSD / ISO 文件
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let f as URL in enumerator {
                        let ext = f.pathExtension.lowercased()
                        if ext == "dsf" || ext == "dff" || ext == "iso" { files.append(f) }
                    }
                }
            } else {
                let ext = url.pathExtension.lowercased()
                if ext == "dsf" || ext == "dff" || ext == "iso" { files.append(url) }
            }
        }
        // 按路径自然排序，保证专辑曲序（01、02…）
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        var added: [PlaylistItem] = []
        var failures: [String] = []
        for url in files {
            if url.pathExtension.lowercased() == "iso" {
                // SACD ISO：展开为曲目列表
                do {
                    let iso = try SacdISO(url: url)
                    isoCache[url.path] = iso
                    for t in iso.album.tracks {
                        let info = DSDInfo(formatName: "SACD", dsdSampleRate: 2_822_400,
                                           channelCount: iso.album.channelCount,
                                           totalSamplesPerChannel: UInt64(t.durationSeconds * 75 * 4704 * 8))
                        let title = t.title.isEmpty ? "Track \(t.index + 1)" : t.title
                        added.append(PlaylistItem(isoURL: url, info: info,
                                                  trackIndex: t.index, title: title))
                    }
                } catch {
                    failures.append(url.lastPathComponent)
                }
                continue
            }
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
            select(at: idx)
        }
        persist()
    }

    func remove(at offsets: IndexSet) {
        let removingCurrent = currentIndex.map { offsets.contains($0) } ?? false
        playlist.remove(atOffsets: offsets)
        if removingCurrent {
            engineQueue.async { self.engine.stop() }
            state = .stopped
            currentIndex = nil
            position = 0
            coverImage = nil
        } else if let cur = currentIndex {
            // 索引随删除前移
            let removed = offsets.filter { $0 < cur }.count
            currentIndex = cur - removed
        }
        persist()
    }

    /// 拖拽排序：sources 中的条目保持相对顺序，整体插入到原数组边界 boundary 处
    /// （boundary ∈ 0...count，表示"插到原第 boundary 项之前"）
    func move(from sources: IndexSet, toBoundary boundary: Int) {
        guard !sources.isEmpty else { return }
        let order = Self.reorderedIndices(count: playlist.count, sources: sources, boundary: boundary)
        let current = currentIndex.map { playlist[$0] }
        playlist = order.map { playlist[$0] }
        if let current, let i = playlist.firstIndex(of: current) {
            currentIndex = i   // 当前播放曲目随排序重定位
        }
        persist()
    }

    /// 重排下标：sources（保持相对顺序）从原数组取出后插入 boundary 边界处
    nonisolated static func reorderedIndices(count: Int, sources: IndexSet, boundary: Int) -> [Int] {
        let moving = sources.sorted()
        guard !moving.isEmpty, moving.count <= count else { return Array(0..<count) }
        var arr = Array(0..<count)
        let removedBefore = moving.filter { $0 < boundary }.count
        let insertAt = max(0, min(count - moving.count, boundary - removedBefore))
        arr.removeAll { sources.contains($0) }
        arr.insert(contentsOf: moving, at: insertAt)
        return arr
    }

    // MARK: 封面
    @Published var coverImage: NSImage?
    private let coverCacheLock = NSLock()
    nonisolated(unsafe) private var coverCache: [String: Data?] = [:]   // nil = 已确认无封面

    /// 封面缓存键：文件路径 + ISO 曲目号
    nonisolated private func coverKey(for item: PlaylistItem) -> String {
        item.url.path + (item.isoTrackIndex.map { "#track=\($0)" } ?? "")
    }

    /// 加载条目封面（带缓存）；无封面返回 nil
    nonisolated func loadCover(for item: PlaylistItem) -> Data? {
        let key = coverKey(for: item)
        coverCacheLock.lock()
        if let cached = coverCache[key] {
            coverCacheLock.unlock()
            return cached
        }
        coverCacheLock.unlock()
        let data = CoverArt.extract(from: item.url)
        coverCacheLock.lock()
        coverCache[key] = data
        coverCacheLock.unlock()
        return data
    }

    /// 切歌后刷新封面（缓存命中则同步显示）
    private func refreshCover() {
        guard let item = currentItem else {
            coverImage = nil
            return
        }
        coverImage = loadCover(for: item).flatMap { NSImage(data: $0) }
    }

    // MARK: 播放控制

    /// 仅更新 UI 选中状态（不触碰引擎）；乐观更新进度与电平，切歌瞬间界面即反映
    private func select(at index: Int) {
        guard playlist.indices.contains(index) else { return }
        currentIndex = index
        position = 0
        meterL = 0
        meterR = 0
        refreshCover()
        persist()
    }

    /// 打开/加载/开播放到引擎队列异步执行：主线程立即更新选中项，
    /// 声音就绪前界面已响应；generation 防止快速连点时旧任务覆盖新状态
    func play(at index: Int) {
        guard let dev = selectedDevice else {
            statusMessage = "Select an output device"
            return
        }
        guard playlist.indices.contains(index) else { return }
        select(at: index)
        playGeneration &+= 1
        let gen = playGeneration
        switchingCount += 1
        let item = playlist[index]
        let devID = dev.id, devUID = dev.uid
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.engine.pcmRateBoost = Self.supportedBoost(
                baseRate: Int(item.info.dsdSampleRate) / 32,
                preferred: self.pcmRateBoost, device: dev)
            var error: Error?
            do {
                let src = try self.openSource(for: item)
                try self.engine.load(source: src)
                try self.engine.play(device: devID)
            } catch let e {
                error = e
            }
            DispatchQueue.main.async {
                self.switchingCount -= 1
                guard self.playGeneration == gen else { return }
                if let error {
                    self.statusMessage = error.localizedDescription
                    return
                }
                self.position = 0
                self.statusMessage = ""
                self.playingDeviceUID = devUID
                self.refreshCover()
                self.queueNextForGapless()
                self.updateNowPlaying()
            }
        }
    }

    /// 优先无缝切换（同规格曲目保持音频链路不断），否则完整重开
    private func playOrSwitch(to index: Int) {
        guard playlist.indices.contains(index) else { return }
        if let src = try? openSource(for: playlist[index]), engine.switchTrack(src) {
            currentIndex = index
            position = 0
            refreshCover()
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
            if switchingCount > 0 { return }   // 加载中，忽略重复指令
            guard let idx = currentIndex ?? (playlist.isEmpty ? nil : 0) else { return }
            play(at: idx)
        case .playing:
            engineQueue.async { self.engine.pause() }
        case .paused:
            guard let dev = selectedDevice else { return }
            engineQueue.async {
                do { try self.engine.play(device: dev.id) }
                catch { DispatchQueue.main.async { self.statusMessage = error.localizedDescription } }
            }
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
        engineQueue.async { self.engine.seek(toSeconds: seconds) }
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
    let crtGlow: Bool           // CRT 荧光效果（Terminal 皮肤：文字晕光 + 扫描线）
    let proLook: Bool           // 专业仪器风格（仅 Dark：香槟金/等宽读数/VU 渐变/Bit-Perfect 标识/微渐变）

    /// 强调色上的对比文字色：按亮度选黑/白
    var onAccent: Color {
        luminance(accent) > 0.45 ? Color.black.opacity(0.85) : .white
    }
}

/// 颜色亮度（0...1，用于对比文字自适应）
func luminance(_ color: Color) -> Double {
    guard let c = NSColor(color).usingColorSpace(.sRGB) else { return 1 }
    return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self = Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
    var hexString: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

enum Skin: Int, CaseIterable, Identifiable {
    case dark
    case braun
    case terminal

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .dark: return "Default"
        case .braun: return "Braun Retro"
        case .terminal: return "Terminal Green"
        }
    }

    var theme: Theme {
        switch self {
        case .dark:
            return Theme(
                bgTop: Color(red: 0.0706, green: 0.0706, blue: 0.0706),   // #121212
                bgBottom: Color(red: 0.0706, green: 0.0706, blue: 0.0706),
                accent: Color(red: 0.93, green: 0.68, blue: 0.30),   // 保持原金色
                badgeBg: Color.white.opacity(0.08),
                isDark: true,
                physicalButtons: false,
                dotGrid: false,
                crtGlow: false,
                proLook: true)
        case .braun:
            // 博朗复古设备：暖米白机身、橙红按键、拟物圆形按钮、面板点阵
            return Theme(
                bgTop: Color(red: 0.937, green: 0.929, blue: 0.902),
                bgBottom: Color(red: 0.878, green: 0.867, blue: 0.831),
                accent: Color(red: 0.875, green: 0.33, blue: 0.12),
                badgeBg: Color.black.opacity(0.07),
                isDark: false,
                physicalButtons: true,
                dotGrid: false,
                crtGlow: false,
                proLook: false)
        case .terminal:
            // 绿磷光终端：墨绿底 + CRT 荧光 + 等宽字体
            return Theme(
                bgTop: Color(red: 0.03, green: 0.10, blue: 0.06),   // 更浓的墨绿
                bgBottom: Color(red: 0.02, green: 0.07, blue: 0.04),
                accent: Color(red: 0.24, green: 0.94, blue: 0.45),
                badgeBg: Color(red: 0.24, green: 0.94, blue: 0.45).opacity(0.12),
                isDark: true,
                physicalButtons: false,
                dotGrid: false,
                crtGlow: true,
                proLook: false)
        }
    }
}

// MARK: - 主界面

struct ContentView: View {
    @EnvironmentObject var model: PlayerModel
    @State private var selection = Set<PlaylistItem.ID>()
    @State private var anchorIndex: Int?   // Shift 范围选择的锚点
    @State private var draggingID: PlaylistItem.ID?   // 正在拖拽的条目
    @State private var dropIndex: Int?   // 插入位置（0...count，nil = 无）
    @State private var showCoverPreview = false   // 封面大图预览
    @State private var holeFreeRects: [CGRect] = []
    @State private var activeWarning: String?   // 非 nil 时弹告警窗
    @State private var deviceHover = false
    @State private var showColorPanel = false   // 颜色定制面板

    private var theme: Theme { model.effectiveTheme }

    /// 半透明模式：Default 皮肤且背景透明度 < 1。
    /// 此时整窗只由根部背景绘制一次，面板/列表不再铺第二层同色底，
    /// 避免重叠的半透明填充叠加混合（标题栏与面板颜色不一致）
    private var isTranslucent: Bool {
        model.skin == .dark && (model.customBgOpacity ?? 1) < 0.999
    }

    /// 时间字体：Terminal 用液晶数字（DB LCD Temp）并放大
    private var timeFont: Font {
        theme.crtGlow ? .custom("DB LCD Temp", size: 18) : .caption.monospacedDigit()
    }

    var body: some View {
        VStack(spacing: 0) {
            // 上部面板：正文正常布局，不做任何手动补偿
            VStack(spacing: 0) {
                header
                nowPlaying
                transport
            }
            .background(Group {
                if isTranslucent { Color.clear } else { faceplateBackground }
            })
            if model.showPlaylist {
                Divider().overlay(theme.crtGlow ? theme.accent.opacity(0.18) : (theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.12)))
                playlistView
                    // 不透明盖住冲孔；半透明时不再铺第二层（避免叠加混合）
                    .background(Group {
                        if isTranslucent { Color.clear } else { theme.bgBottom }
                    })
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))   // 窗口圆角内裁剪（透明背景时必需）
        .coordinateSpace(name: "root")
        .onPreferenceChange(HoleFreeRectKey.self) { holeFreeRects = $0 }
        // 列表展开时填满窗口（多余高度由列表区域吸收）；收起时内容自适应使窗口收缩
        .frame(maxHeight: model.showPlaylist ? .infinity : nil, alignment: .top)
        // 背景负责延伸进标题栏（仅背景忽略顶部安全区，正文保持正常布局）；
        // 背景不参与内容尺寸计算，窗口保持固定不可拖大。
        // 半透明模式整窗只有这一层填充；圆角裁剪让四角露出桌面
        .background {
            Group {
                if theme.dotGrid {
                    holeCanvas
                } else {
                    theme.bgTop   // 与面板同一个颜色来源
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .ignoresSafeArea(.container, edges: .top)
        }
        // 隐藏按钮承载快捷键：方向键快进退、Delete 删除选中、上下键移动选择
        .background(
            HStack {
                Button("") { model.seekBy(-5) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { model.seekBy(5) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { removeSelection() }.keyboardShortcut(.delete, modifiers: [])
                Button("") { moveSelection(-1, extend: false) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("") { moveSelection(1, extend: false) }.keyboardShortcut(.downArrow, modifiers: [])
                Button("") { moveSelection(-1, extend: true) }.keyboardShortcut(.upArrow, modifiers: .shift)
                Button("") { moveSelection(1, extend: true) }.keyboardShortcut(.downArrow, modifiers: .shift)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        )
        .preferredColorScheme(theme.isDark ? .dark : .light)
        // CRT 扫描线 + 暗角（Terminal 皮肤）
        .overlay {
            if theme.crtGlow {
                ZStack {
                    Canvas { ctx, size in
                        var y: CGFloat = 0
                        while y < size.height {
                            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                                     with: .color(.black.opacity(0.10)))
                            y += 3
                        }
                    }
                    // 暗角：四周轻微压暗，模拟 CRT 玻璃
                    GeometryReader { geo in
                        RadialGradient(colors: [.clear, .black.opacity(0.22)],
                                       center: .center,
                                       startRadius: min(geo.size.width, geo.size.height) * 0.45,
                                       endRadius: max(geo.size.width, geo.size.height) * 0.8)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        // 告警：出现新告警时弹窗（顶栏不再有常驻告警图标）；
        // onAppear 兜底处理启动时（视图挂载前）就存在的告警
        .onChange(of: model.warningText) { _, new in
            if let new { activeWarning = new }
        }
        .onAppear { activeWarning = model.warningText }
        .alert("Warning", isPresented: Binding(
            get: { activeWarning != nil },
            set: { if !$0 { activeWarning = nil } })) {
            Button("OK") { activeWarning = nil }
        } message: {
            Text(activeWarning ?? "")
        }
        // 退出 App 时停止引擎：释放独占并恢复被 DoP 强制为 1.0 的音量
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.engine.stop()
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)   // 去掉标题栏系统材质
        // 封面大图预览：点击封面打开，点任意处关闭
        .overlay {
            if showCoverPreview, let img = model.coverImage {
                CoverPreview(image: img) { showCoverPreview = false }
            }
        }
        .frame(width: 560)
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

    @ViewBuilder
    private var faceplateBackground: some View {
        // 纯色面板：与标题栏（外层背景 bgTop）严格同源同色
        if theme.proLook {
            // 专业仪器：极淡的顶部微亮渐变（金属面板质感）
            theme.bgTop.overlay(
                LinearGradient(colors: [Color.white.opacity(0.04), Color.clear],
                               startPoint: .top, endPoint: .bottom))
        } else {
            theme.bgTop
        }
    }

    /// 封面缩略图：无封面时显示主题化占位图标（波形），不留空白
    private var coverArt: some View {
        Group {
            if let img = model.coverImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    theme.accent.opacity(0.12)
                    Image(systemName: "waveform.path")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(theme.accent.opacity(0.85))
                }
            }
        }
        .frame(width: 78, height: 78)   // 与右栏三行（歌名+信息+进度）总高一致
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            if model.coverImage != nil { showCoverPreview = true }
        }
        .onHover { h in
            if model.coverImage != nil {
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .help(model.coverImage != nil ? "Click to view full size" : "")
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.12), lineWidth: 1))
        .holeFreeZone()
    }

    // 顶栏: 标题 + 输出模式 + 设备 + 皮肤
    private var header: some View {
        ZStack {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.accent)
                    Text("DSD Player")
                        .font(.custom("Arial Rounded MT Bold", size: 18))   // 博朗商标风格圆润粗体
                }
                .holeFreeZone()
                Spacer()
                // 胶囊底：与输出模式开关同一规格（28pt 高、主题徽标底色填充）
                // 注意：borderlessButton 的 Menu 会吞掉 label 上的自定义背景，所以胶囊画在外层
                HStack(spacing: 0) {
                    Menu {
                        ForEach(model.devices) { dev in
                            Button {
                                model.selectedDevice = dev
                            } label: {
                                let name = dev.name + (dev.isUSB ? " ⚡" : "")
                                if dev == model.selectedDevice {
                                    Label(name, systemImage: "checkmark")
                                } else {
                                    Text(name)
                                }
                            }
                        }
                        Divider()
                        Button("Refresh Devices") { model.refreshDevices() }
                    } label: {
                        HStack(spacing: 4) {
                            // 字符串级截断：Menu label 的 frame(maxWidth:) 度量不可靠，手动测量截断
                            Text(truncatedDeviceName(model.selectedDevice?.name ?? "No Device"))
                                .font(.callout)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(deviceHover ? theme.accent : Color.secondary)
                            Spacer(minLength: 0)   // 内容靠左，右侧留白
                        }
                        .padding(.horizontal, 4)
                        .frame(width: 164, alignment: .leading)   // 固定 label 宽度 = 胶囊宽度，内容左对齐
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .onHover { deviceHover = $0 }
                }
                .frame(width: 164, height: 28)   // 固定宽度：设备名变化不跳动
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.isDark
                              ? Color.white.opacity(deviceHover ? 0.14 : 0.09)
                              : Color.black.opacity(deviceHover ? 0.1 : 0.05))
                        // 拟物皮肤加投影（只投影胶囊底，不带文字）
                        .shadow(color: theme.physicalButtons ? .black.opacity(0.25) : .clear,
                                radius: 2, y: 1.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(deviceHover
                                ? theme.accent.opacity(0.6)
                                : (theme.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.14)),
                                lineWidth: 1)
                )
                .animation(.easeOut(duration: 0.15), value: deviceHover)
                .holeFreeZone()
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
                    Divider()
                    Button("Custom Colors…") { showColorPanel = true }
                } label: {
                    Image(systemName: "tshirt")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)
                .help("Skin")
                .hoverBrightness()
                .holeFreeZone()
                .popover(isPresented: $showColorPanel, arrowEdge: .bottom) {
                    ColorPanelView(model: model)
                }
            }
            // 输出模式开关：面板级居中（叠层实现，不受左右内容影响）
            ModePicker(mode: Binding(
                get: { model.outputMode },
                set: { model.setOutputMode($0) }), theme: theme)
            .help("DoP: bit-perfect to DoP-capable DACs; PCM: convert to hi-res PCM, works on any device")
            .holeFreeZone()
        }
        .padding(.horizontal, 16)
        .padding(.top, 3)   // 与红绿灯同处标题栏一行
        .padding(.bottom, 12)
    }

    // 当前曲目信息
    private var nowPlaying: some View {
        VStack(spacing: 10) {
            // 封面 + 右栏（歌名 / 格式信息 / 进度），封面高度与右栏三行总高一致
            HStack(spacing: 12) {
                coverArt
                VStack(spacing: 8) {
                    MarqueeText(text: model.currentItem?.title ?? "No Track Loaded",
                                font: theme.crtGlow ? .custom("Menlo-Bold", size: 17) : .title3.weight(.semibold),
                                showCursor: theme.crtGlow, cursorColor: theme.accent)
                        .foregroundStyle(model.currentItem == nil ? .secondary : .primary)
                        .crtGlowText(theme)
                        .frame(maxWidth: 420)   // 固定宽度，超出部分滚动显示
                        .holeFreeZone()

                    if let info = model.currentInfo {
                        // 信号链：源规格 → 输出方式与载波率（窄条排版，字号保持 caption）
                        HStack(spacing: 4) {
                            Text("DSD\(info.dsdMultiple) · \(String(format: "%.1f", Double(info.dsdSampleRate) / 1e6))MHz · \(channelLabel(info.channelCount))")
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                            if model.outputMode == .dop {
                                Text("DoP \(Int(info.dopCarrierRate / 1000))kHz")
                                    .foregroundStyle(theme.accent)
                            } else {
                                // PCM 输出采样率：点击切换（DSD率/32 的 1/2/4 倍），
                                // 设备不支持的档位禁用，勾选的是实际生效档（可能被设备能力降档）
                                let base = Int(info.dsdSampleRate) / 32
                                let eff = PlayerModel.supportedBoost(
                                    baseRate: base, preferred: model.pcmRateBoost,
                                    device: model.selectedDevice ?? OutputDevice(id: 0, uid: "", name: "", isUSB: false, supportedRates: []))
                                Menu {
                                    ForEach(0..<3, id: \.self) { b in
                                        let rate = base * (1 << b)
                                        let ok = model.selectedDevice?.supports(rate: Double(rate)) ?? true
                                        Button {
                                            model.setPcmRateBoost(b)
                                        } label: {
                                            if eff == b {
                                                Label("\(rate / 1000)kHz", systemImage: "checkmark")
                                            } else {
                                                Text("\(rate / 1000)kHz")
                                            }
                                        }
                                        .disabled(!ok)
                                    }
                                } label: {
                                    Text("\(base * (1 << eff) / 1000)kHz")
                                        .foregroundStyle(theme.accent)
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("PCM output sample rate (click to change)")
                            }
                            // Bit-Perfect 标识：DoP 位元直通播放时点亮（所有皮肤显示，保证布局一致）
                            HStack(spacing: 3) {
                                Circle().fill(theme.accent).frame(width: 4, height: 4)
                                Text("Bit-Perfect")
                            }
                            .opacity(model.outputMode == .dop && model.state == .playing ? 1 : 0.25)
                            .foregroundStyle(theme.accent)
                        }
                        .font(theme.proLook ? .caption.monospaced() : .caption.monospacedDigit())   // 专业仪器读数用等宽字体
                        .crtGlowText(theme)
                        .holeFreeZone()
                    } else {
                        Text("Add .dsf / .dff files to start playing")
                            .font(.caption).foregroundStyle(.secondary)
                            .holeFreeZone()
                    }

                    // 进度（位于封面右侧栏内，随封面加宽而缩短）
                    HStack(spacing: 10) {
                        Text(formatTime(model.position))
                            .font(timeFont)   // Terminal 用液晶数字并放大
                            .foregroundStyle(.secondary)
                            .frame(height: 22)   // 所有皮肤统一时间标签高度
                            .crtGlowText(theme)
                        ThemedSlider(
                            value: Binding(
                                get: { model.position },
                                set: { model.position = $0 }),
                            upperBound: max(1, model.currentInfo?.durationSeconds ?? 1),
                            enabled: model.state != .idle,
                            theme: theme,
                            onEditingEnded: { model.seek(to: model.position) })
                        Text(formatTime(model.currentInfo?.durationSeconds ?? 0))
                            .font(timeFont)
                            .foregroundStyle(.secondary)
                            .frame(height: 22)
                            .crtGlowText(theme)
                    }
                    .holeFreeZone()
                    .padding(.trailing, 20)   // 进度条进一步收窄
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

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
                TransportButton(icon: model.playMode.icon, size: 18, theme: theme,
                                active: model.playMode != .sequential,
                                help: model.playMode.label,
                                enabled: !model.playlist.isEmpty) {
                    model.playMode = model.playMode.next()
                }
                TransportButton(icon: "backward.fill", size: 22, theme: theme,
                                help: "Previous (⌘←)",
                                enabled: !model.playlist.isEmpty) { model.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                // 播放/暂停主按钮：所有皮肤统一 64×64 容器（绝对位置一致）
                Button { model.togglePlay() } label: {
                    Group {
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
                        } else if theme.crtGlow {
                            // 终端：方形播放/暂停按钮（pause.square.fill 不存在，暂停自绘）
                            if model.state == .playing {
                                SquarePauseIcon(theme: theme)
                            } else {
                                Image(systemName: "play.square.fill")
                                    .font(.system(size: 46))
                                    .foregroundStyle(theme.accent)
                            }
                        } else {
                            Image(systemName: model.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 46))
                                .foregroundStyle(theme.accent)
                        }
                    }
                    .frame(width: 64, height: 64)   // 所有皮肤统一占位
                }
                .buttonStyle(PressScaleStyle())
                .disabled(model.playlist.isEmpty)
                .keyboardShortcut(.space, modifiers: [])
                .hoverBrightness()
                TransportButton(icon: "forward.fill", size: 22, theme: theme,
                                help: "Next (⌘→)",
                                enabled: !model.playlist.isEmpty) { model.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                // 列表显隐
                TransportButton(icon: "list.bullet", size: 18, theme: theme,
                                active: model.showPlaylist,
                                help: model.showPlaylist ? "Hide Playlist" : "Show Playlist",
                                enabled: true) {
                    model.showPlaylist.toggle()
                }
            }
            .holeFreeZone()
            Spacer()
        }
        .padding(.top, 6)
        .padding(.bottom, 30)   // 播放按钮下方 1 行冲孔 + 正常边距
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
                // 自绘选中高亮（主题强调色），不用 List 的系统蓝
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.playlist.enumerated()), id: \.element.id) { idx, item in
                            if dropIndex == idx {
                                dropIndicator   // 插入位置指示线
                            }
                            playlistRow(idx: idx, item: item)
                                .background {
                                    GeometryReader { geo in
                                        Color.clear.onDrop(
                                            of: [UTType.plainText, UTType.fileURL],
                                            delegate: PlaylistRowDropDelegate(
                                                index: idx, rowHeight: geo.size.height,
                                                draggingID: $draggingID, dropIndex: $dropIndex,
                                                perform: performRowMove,
                                                onFiles: { urls in model.add(urls: urls) }))
                                    }
                                }
                                .contextMenu {
                                    if selection.contains(item.id), selection.count > 1 {
                                        Button("Remove \(selection.count) Tracks") { removeSelection() }
                                    } else {
                                        Button("Remove") {
                                            if let i = model.playlist.firstIndex(of: item) {
                                                model.remove(at: IndexSet(integer: i))
                                            }
                                            selection = []
                                            anchorIndex = nil
                                        }
                                    }
                                }
                            if idx < model.playlist.count - 1 {
                                Divider()
                                    .overlay(theme.crtGlow ? theme.accent.opacity(0.15) : (theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08)))
                                    .padding(.leading, 36)
                            }
                        }
                        if dropIndex == model.playlist.count {
                            dropIndicator   // 末尾插入指示线
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(height: 360)   // 固定高度：约 10 行
                // 拖到列表空白区域 = 放到末尾
                .onDrop(of: [UTType.plainText, UTType.fileURL], delegate: PlaylistRowDropDelegate(
                    index: model.playlist.count, rowHeight: .infinity,
                    draggingID: $draggingID, dropIndex: $dropIndex,
                    perform: performRowMove,
                    onFiles: { urls in model.add(urls: urls) }))
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
        let isSelected = selection.contains(item.id)
        let isCurrent = model.currentIndex == idx
        // 选中底上的对比文字色：按强调色亮度自适应
        let onAccent: Color = theme.onAccent
        return HStack(spacing: 10) {
            if isCurrent {
                Image(systemName: model.state == .playing ? "waveform" : "pause")
                    .font(.caption)
                    .foregroundStyle(isSelected ? onAccent : theme.accent)
                    .frame(width: 18)
            } else {
                Text("\(idx + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? onAccent.opacity(0.7) : .secondary)
                    .frame(width: 18)
            }
            Text(item.title)
                .font(theme.crtGlow ? .callout.monospaced() : .body)
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(isSelected ? onAccent : (isCurrent ? theme.accent : .primary))
            Spacer()
            badge("DSD\(item.info.dsdMultiple)", small: true, onAccent: isSelected)
            Text(formatTime(item.info.durationSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(isSelected ? onAccent.opacity(0.7) : .secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? theme.accent.opacity(0.9) : Color.clear)
        )
        .frame(height: 34)
        .crtGlowText(theme)
        .contentShape(Rectangle())
        .onDrag {
            draggingID = item.id
            return NSItemProvider(object: item.id.uuidString as NSString)
        }
        .onTapGesture(count: 2) { model.play(at: idx) }
        .onTapGesture(count: 1) { handleSelect(idx: idx, item: item) }
    }

    /// 单击选择：普通点击单选；⌘点击切换加选/取消；⇧点击从锚点范围选择
    private func handleSelect(idx: Int, item: PlaylistItem) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchorIndex = idx
        } else if mods.contains(.shift), let anchor = anchorIndex,
                  model.playlist.indices.contains(anchor) {
            let range = min(anchor, idx)...max(anchor, idx)
            selection = Set(range.map { model.playlist[$0].id })
        } else {
            selection = [item.id]
            anchorIndex = idx
        }
    }

    /// 键盘上下移动选择；Shift 从锚点扩展
    private func moveSelection(_ delta: Int, extend: Bool) {
        guard !model.playlist.isEmpty else { return }
        let cur = anchorIndex ?? model.currentIndex ?? (delta > 0 ? -1 : 0)
        let next = max(0, min(model.playlist.count - 1, cur + delta))
        if extend {
            let range = min(cur, next)...max(cur, next)
            selection = Set(range.map { model.playlist[$0].id })
        } else {
            selection = [model.playlist[next].id]
            anchorIndex = next
        }
    }

    /// 删除所有选中的曲目
    private func removeSelection() {
        guard !selection.isEmpty else { return }
        let idxs = IndexSet(model.playlist.indices.filter { selection.contains(model.playlist[$0].id) })
        model.remove(at: idxs)
        selection = []
        anchorIndex = nil
    }

    // MARK: 拖拽排序

    /// 插入位置指示线
    private var dropIndicator: some View {
        Rectangle()
            .fill(theme.accent)
            .frame(height: 2)
            .padding(.horizontal, 8)
    }

    /// 放下执行移动：若被拖条目在多选集内则整组移动（保持相对顺序）
    private func performRowMove(targetIndex: Int, insertBefore: Bool) -> Bool {
        defer { draggingID = nil; dropIndex = nil }
        guard let draggingID else { return false }
        let sources: IndexSet
        if selection.contains(draggingID), selection.count > 1 {
            sources = IndexSet(model.playlist.indices.filter { selection.contains(model.playlist[$0].id) })
        } else {
            sources = IndexSet(model.playlist.indices.filter { model.playlist[$0].id == draggingID })
        }
        let boundary = insertBefore ? targetIndex : targetIndex + 1
        model.move(from: sources, toBoundary: boundary)
        return true
    }

    private func channelLabel(_ count: Int) -> String {
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        default: return "\(count)ch"
        }
    }

    /// 设备名截断：用 NSFont 实际测量，超过 maxWidth 时尾部加省略号
    private func truncatedDeviceName(_ name: String, maxWidth: CGFloat = 130) -> String {
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (name as NSString).size(withAttributes: attrs).width <= maxWidth { return name }
        var s = name
        while !s.isEmpty,
              ((s + "…") as NSString).size(withAttributes: attrs).width > maxWidth {
            s.removeLast()
        }
        return s + "…"
    }

    private func badge(_ text: String, highlight: Bool = false, small: Bool = false,
                       onAccent: Bool = false) -> some View {
        let onAccentText: Color = theme.onAccent
        return Text(text)
            .font(small ? .caption2 : .caption)
            .padding(.horizontal, small ? 5 : 7).padding(.vertical, small ? 1 : 3)
            .background(onAccent
                        ? (theme.isDark ? Color.black.opacity(0.25) : Color.white.opacity(0.25))
                        : (highlight ? theme.accent.opacity(0.22) : theme.badgeBg))
            .foregroundStyle(onAccent ? onAccentText
                             : (highlight ? theme.accent : Color.primary.opacity(0.75)))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - 方形暂停图标（Terminal：pause.square.fill 不存在，自绘）

struct SquarePauseIcon: View {
    let theme: Theme
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(theme.accent)
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1).fill(theme.bgTop).frame(width: 5, height: 17)
                RoundedRectangle(cornerRadius: 1).fill(theme.bgTop).frame(width: 5, height: 17)
            }
        }
        .frame(width: 38, height: 38)
        .shadow(color: theme.accent.opacity(0.5), radius: 4)
    }
}

// MARK: - 主题化进度滑杆

/// 主题化进度条：主题色轨道填充 + 旋钮；悬停/拖动时旋钮放大；点击跳转
struct ThemedSlider: View {
    @Binding var value: Double
    var upperBound: Double
    var enabled: Bool = true
    let theme: Theme
    var onEditingEnded: () -> Void = {}

    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = upperBound > 0 ? min(1, max(0, value / upperBound)) : 0
            let knobD: CGFloat = dragging ? 18 : (hovering ? 16 : 13)
            ZStack(alignment: .leading) {
                // 轨道
                Capsule().fill(theme.badgeBg).frame(height: 4)
                Capsule().fill(theme.accent.opacity(enabled ? 0.9 : 0.4))
                    .frame(width: max(0, frac * w), height: 4)
                // 旋钮
                knob(diameter: knobD)
                    .offset(x: frac * (w - knobD))
                    .animation(.easeOut(duration: 0.15), value: dragging)
                    .animation(.easeOut(duration: 0.12), value: hovering)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(enabled ? DragGesture(minimumDistance: 0)
                .onChanged { g in
                    dragging = true
                    value = max(0, min(upperBound, Double(g.location.x / w) * upperBound))
                }
                .onEnded { _ in
                    dragging = false
                    onEditingEnded()
                } : nil)
            .onHover { hovering = $0 }
        }
        .frame(height: 20)
        .opacity(enabled ? 1 : 0.45)
    }

    @ViewBuilder
    private func knob(diameter d: CGFloat) -> some View {
        if theme.crtGlow {
            // 终端风格：竖条矩形旋钮
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.accent)
                .frame(width: 8, height: 18)
                .shadow(color: theme.accent.opacity(0.6), radius: 3)
        } else {
        Circle()
            .fill(theme.physicalButtons ? Color.white : theme.accent)
            .frame(width: d, height: d)
            .overlay(
                Circle().stroke(theme.physicalButtons ? theme.accent : .clear,
                                lineWidth: theme.physicalButtons ? 2 : 0)
            )
            .shadow(color: theme.physicalButtons ? .black.opacity(0.3)
                    : theme.accent.opacity(dragging ? 0.6 : 0.3),
                    radius: theme.physicalButtons ? 2 : (dragging ? 4 : 2),
                    y: theme.physicalButtons ? 1.5 : 0)
        }
    }
}

// MARK: - 颜色定制面板（仅 Dark 皮肤）

struct ColorPanelView: View {
    @ObservedObject var model: PlayerModel

    // Dark 默认色：金色 + #121212
    private let defaultAccent = Color(red: 0.93, green: 0.68, blue: 0.30)
    private let defaultBg = Color(red: 0.0706, green: 0.0706, blue: 0.0706)

    private var accentBinding: Binding<Color> {
        Binding(
            get: { model.customAccentHex.flatMap(Color.init(hex:)) ?? defaultAccent },
            set: { model.setCustomAccent($0) })
    }
    private var bgBinding: Binding<Color> {
        Binding(
            get: { model.customBgHex.flatMap(Color.init(hex:)) ?? defaultBg },
            set: { model.setCustomBg($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Default Skin Colors")
                .font(.headline)
            ColorPicker("Accent", selection: accentBinding, supportsOpacity: false)
            ColorPicker("Background", selection: bgBinding, supportsOpacity: false)
            HStack(spacing: 8) {
                Text("Opacity").frame(width: 76, alignment: .leading)
                Slider(value: Binding(
                    get: { model.customBgOpacity ?? 1 },
                    set: { model.setCustomBgOpacity($0) }), in: 0.15...1)
                Text("\(Int((model.customBgOpacity ?? 1) * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button("Reset to Defaults") { model.resetCustomColors() }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 250)
    }
}

// MARK: - 主题化输出模式开关

/// DoP/PCM 分段开关：选中段用主题强调色，轨道用主题底色，随皮肤变化
struct ModePicker: View {
    @Binding var mode: OutputMode
    let theme: Theme
    @State private var hovering: OutputMode?

    var body: some View {
        HStack(spacing: 2) {
            segment("DoP", .dop)
            segment("PCM", .pcm)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.badgeBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1),
                        lineWidth: 0.5)
        )
    }

    private func segment(_ label: String, _ value: OutputMode) -> some View {
        let selected = mode == value
        return Button { mode = value } label: {
            Text(label)
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected
                                 ? theme.onAccent
                                 : Color.primary.opacity(hovering == value ? 0.9 : 0.55))
                .frame(width: 52, height: 22)
                .crtGlowText(theme)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.accent)
                            .shadow(color: theme.accent.opacity(0.5), radius: theme.physicalButtons ? 0 : 4)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 ? value : nil }
        .animation(.easeOut(duration: 0.15), value: mode)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - 按钮交互反馈

/// 按下缩放动画（所有可点按钮通用）
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// CRT 荧光文字晕光（仅 Terminal 皮肤）
extension View {
    func crtGlowText(_ theme: Theme) -> some View {
        shadow(color: theme.crtGlow ? theme.accent.opacity(0.65) : .clear, radius: 2.5)
    }
}

/// 悬停增亮（用于播放主按钮等大图标）
extension View {
    func hoverBrightness() -> some View { modifier(HoverBrightness()) }
}

private struct HoverBrightness: ViewModifier {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View {
        content
            .brightness(hovering && isEnabled ? 0.18 : 0)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// 传输控制按钮：悬停时非拟物皮肤显示圆形底、拟物皮肤加深阴影；按下缩放
struct TransportButton: View {
    let icon: String
    var size: CGFloat
    let theme: Theme
    var active: Bool = false
    var help: String = ""
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: theme.physicalButtons ? .semibold : .regular))
                .foregroundStyle(active ? theme.accent : Color.primary.opacity(hovering ? 1.0 : 0.85))
                .crtGlowText(theme)
                .frame(width: 36, height: 36)
                .background {
                    if theme.physicalButtons {
                        Circle()
                            .fill(theme.bgTop)
                            .shadow(color: .black.opacity(hovering ? 0.42 : 0.3),
                                    radius: hovering ? 3 : 2, y: hovering ? 2 : 1.5)
                            .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                    } else if hovering {
                        Circle().fill(theme.badgeBg)
                    }
                }
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
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
            window.isOpaque = false                         // 允许背景透明（透明度可调）
            window.backgroundColor = .clear
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

// MARK: - 封面大图预览

/// 点击封面查看原图：暗色背景 + 等比大图，点任意处关闭
private struct CoverPreview: View {
    let image: NSImage
    let onClose: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
                .onTapGesture(perform: onClose)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 460, height: 460)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 24)
                .onTapGesture(perform: onClose)
        }
        .frame(width: 560, height: 703)
        .transition(.opacity)
    }
}

// MARK: - 播放列表拖放

/// 行级拖放代理：拖拽悬停时按落点上半/下半计算插入位置，放下时执行整组移动
private struct PlaylistRowDropDelegate: DropDelegate {
    let index: Int            // 目标行下标（拖放目标为空白区时传 count）
    let rowHeight: CGFloat
    @Binding var draggingID: PlaylistItem.ID?
    @Binding var dropIndex: Int?
    let perform: (Int, Bool) -> Bool   // (目标行下标, 插到该行之前)
    let onFiles: ([URL]) -> Void       // 外部文件拖入

    func validateDrop(info: DropInfo) -> Bool {
        if draggingID != nil { return true }
        return info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if draggingID != nil {
            let before = rowHeight == .infinity || info.location.y < rowHeight / 2
            dropIndex = before ? index : index + 1
            return DropProposal(operation: .move)
        }
        return info.hasItemsConforming(to: [UTType.fileURL]) ? DropProposal(operation: .copy) : nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggingID = nil; dropIndex = nil }
        if draggingID != nil {
            let before = rowHeight == .infinity || info.location.y < rowHeight / 2
            return perform(index, before)
        }
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in onFiles([url]) }
            }
        }
        return true
    }

    func dropExited(info: DropInfo) {
        dropIndex = nil
    }
}

// MARK: - 滚动文本（超长歌名往返滚动）

struct MarqueeText: View {
    let text: String
    var font: Font = .title3.weight(.semibold)
    var showCursor = false      // Terminal 皮肤：光标紧跟文字末尾
    var cursorColor: Color = .primary

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
                    contentWithCursor
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .offset(x: -scrollDistance(at: context.date, overflow: overflow))
                }
            } else {
                contentWithCursor
                    .frame(maxWidth: .infinity, alignment: .leading)   // 左对齐
            }
        }
        .frame(height: 26)
        .clipped()
        .onChange(of: text) { startDate = Date() }
    }

    @ViewBuilder
    private var contentWithCursor: some View {
        HStack(spacing: 2) {
            Text(text)
                .font(font)
                .lineLimit(1)
            if showCursor {
                TimelineView(.periodic(from: .now, by: 0.8)) { _ in
                    Text("▋")
                        .font(font)
                        .foregroundStyle(cursorColor)
                        .opacity(Int(Date().timeIntervalSince1970 / 0.8) % 2 == 0 ? 1 : 0.1)
                }
            }
        }
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
        // Canvas 绘制：段宽对齐到整像素，避免 HStack 分配小数宽度导致粗细不均
        Canvas { ctx, size in
            let lampD: CGFloat = 13
            let gap: CGFloat = 6
            let sideW = (size.width - lampD - gap * 2) / 2
            let n = segments
            let spacing: CGFloat = 1.5
            // 段宽向下取 0.5pt 整数倍（Retina 下 = 整像素）
            let segW = ((sideW - spacing * CGFloat(n - 1)) / CGFloat(n) * 2).rounded(.down) / 2
            let step = segW + spacing
            let actualW = step * CGFloat(n) - spacing

            func drawSide(leftX: CGFloat, level: Double, mirrored: Bool) {
                for i in 0..<n {
                    let fromCenter = mirrored ? Double(n - 1 - i) / Double(n) : Double(i) / Double(n)
                    let lit = fromCenter < norm(level)
                    let rect = CGRect(x: leftX + CGFloat(i) * step,
                                      y: 0, width: segW, height: size.height)
                    let path = Path(roundedRect: rect, cornerRadius: 1.5)
                    ctx.fill(path, with: .color(lit ? segmentColor(fromCenter) : theme.badgeBg))
                }
            }

            // 左声道（从中间向左增长）
            drawSide(leftX: (sideW - actualW) / 2, level: left, mirrored: true)
            // 中央指示灯
            let lampRect = CGRect(x: sideW + gap, y: (size.height - lampD) / 2,
                                  width: lampD, height: lampD)
            ctx.fill(Path(ellipseIn: lampRect),
                     with: .color(isPlaying ? theme.accent : theme.badgeBg))
            // 右声道
            drawSide(leftX: size.width - actualW - (sideW - actualW) / 2, level: right, mirrored: false)
        }
        .frame(height: 13)
    }

    /// 线性 RMS 幅度 → 对数尺度：-60dB 映射到 0，0dB 映射到 1
    private func norm(_ level: Double) -> Double {
        let db = 20 * log10(max(level, 1e-6))
        return max(0, (db + 60) / 60)
    }

    private func segmentColor(_ pos: Double) -> Color {
        if theme.proLook {
            // 专业电平表配色：绿区安全 → 黄区余量 → 红区峰值
            if pos > 0.85 { return Color(red: 0.9, green: 0.3, blue: 0.25) }
            if pos > 0.55 { return Color(red: 0.9, green: 0.7, blue: 0.3) }
            return Color(red: 0.35, green: 0.78, blue: 0.45)
        }
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
