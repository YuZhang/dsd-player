import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

enum OutputMode: Int {
    case dop   // DoP 位元直通（需要 DAC 支持 DoP）
    case pcm   // DSD→PCM 转换（任意设备可用，系统音量可调）
}

/// 统一播放源：DSD 字节流（DSF/DFF/ISO 曲目）或 PCM 采样流（WAV/FLAC）
enum AudioSource {
    case dsd(DSDSource)
    case pcm(PCMSource)

    var info: DSDInfo {
        switch self {
        case .dsd(let s): return s.info
        case .pcm(let s): return s.info
        }
    }
    /// 无缝续播/切换的规格比较键：采样率 + 声道数 + 源种类
    var seamlessKey: (rate: UInt32, channels: Int, pcm: Bool) {
        let i = info
        return (i.dsdSampleRate, i.channelCount, i.isPCM)
    }
}

/// 播放引擎：DSD 文件 → DoP 帧 / PCM 采样 → 环形缓冲 → AUHAL 直出。
/// 渲染回调运行在 CoreAudio 实时线程，只读环形缓冲，不加锁。
final class PlaybackEngine: @unchecked Sendable {

    enum State: Equatable {
        case idle        // 未加载
        case stopped     // 已加载，未播放
        case playing
        case paused
        case finished    // 播完
    }

    private(set) var source: AudioSource?
    var outputMode: OutputMode = .dop
    /// PCM 输出采样率提升档：0 = DSD率/32（88.2k@DSD64），1 = ×2，2 = ×4
    var pcmRateBoost = 0
    /// PCM 模式匹配设备采样率：播放时把设备名义率设为源码输出率（需设备支持），
    /// 避免 HAL 重采样；暂停/停止/换设备时恢复原速率。默认关闭。
    var matchDeviceRate = false

    // PCM 匹配模式保存的原设备速率（暂停/停止时恢复）
    private var savedRateDevice = AudioDeviceID(0)
    private var savedRateValue: Double?


    /// 应用匹配速率：设备支持且当前不一致时，保存原速率并切换
    private func applyMatchedRate(device: AudioDeviceID, rate: Double) {
        guard device != 0 else { return }
        // 换设备先还原旧设备
        if savedRateDevice != 0, savedRateDevice != device { restoreMatchedRate() }
        guard AudioDeviceManager.supportsNominalRate(device, rate: rate) else { return }
        let cur = AudioDeviceManager.nominalRate(device)
        guard cur != rate else { return }
        if savedRateDevice == 0 {
            savedRateValue = cur
            savedRateDevice = device
        }
        AudioDeviceManager.setNominalRate(device, rate: rate)
    }

    /// 恢复进入匹配前保存的设备速率
    private func restoreMatchedRate() {
        guard savedRateDevice != 0 else { return }
        let device = savedRateDevice, value = savedRateValue
        savedRateDevice = 0
        savedRateValue = nil
        if let value { AudioDeviceManager.setNominalRate(device, rate: value) }
    }

    /// 播放中切换匹配开关：立即应用或恢复（引擎队列调用）
    func updateMatchDeviceRate(_ match: Bool) {
        matchDeviceRate = match
        if match, state == .playing, let src = source, effectiveMode == .pcm {
            applyMatchedRate(device: deviceID, rate: Double(outputRate(for: src)))
        } else {
            restoreMatchedRate()
        }
    }

    /// 实际生效的输出模式：PCM 源（WAV/FLAC）只能走 PCM 通路，DoP 开关对它们无效
    private var effectiveMode: OutputMode {
        (source?.info.isPCM ?? false) ? .pcm : outputMode
    }

    /// PCM 输出采样率 = DSD率/32 × 2^boost
    private func pcmRate(for info: DSDInfo) -> Int {
        Int(info.dsdSampleRate) / 32 << max(0, min(2, pcmRateBoost))
    }
    private(set) var state: State = .idle {
        didSet {
            let cb = onStateChange, s = state
            DispatchQueue.main.async { cb?(s) }
        }
    }
    var onStateChange: ((State) -> Void)?
    var onError: ((String) -> Void)?

    private var audioUnit: AudioUnit?
    private var deviceID = AudioDeviceID(0)

    private let ring = RingBuffer(capacity: 1 << 22)  // ~4M 采样
    private var encoder = DoPEncoder()
    private var pcmConverter: DSDToPCM?
    private let modeIsPCM = Atomic<Bool>(false)
    private let channels = Atomic<Int>(2)
    private let carrierRate = Atomic<Int>(0)
    private let renderedFrames = Atomic<Int>(0)       // 已送硬件的 DoP 帧数
    private let feederOffset = Atomic<UInt64>(0)      // 喂数据线程读位置（每声道字节）
    private let totalFrames = Atomic<Int>(0)          // 总 DoP 帧数
    private let eofReached = Atomic<Bool>(false)
    private let feederCancel = Atomic<Bool>(false)
    let underrunFrames = Atomic<Int>(0)   // 诊断: 渲染回调欠载帧数

    private var feederThread: Thread?
    /// 串行化喂数据线程的 read/encode/write 周期与主线程的 seek/stop/load。
    private let feederLock = NSLock()

    // MARK: 无缝播放与防爆音
    /// 预排的下一首（仅当采样率/声道数/源种类与当前相同时保留，实现无缝续播）
    private var pendingNext: AudioSource?
    /// 无缝切换通知（主线程派发）
    var onTrackAdvanced: (() -> Void)?
    private let trackStartFrames = Atomic<Int>(0)      // 当前曲目起点（渲染帧坐标）
    private let pendingBoundary = Atomic<Int>(-1)      // 待生效的曲目切换边界（渲染帧坐标）
    private let pendingTrackFrames = Atomic<Int>(0)    // 新曲目总帧数（边界生效时提交）
    private let pendingSilenceFrames = Atomic<Int>(0)  // DoP 边界静音帧数（防切换爆音）
    private let fadeInSamples = Atomic<Int>(0)         // PCM 边界渐入采样数
    private let silencePhase = Atomic<Int>(0)          // 渲染线程 DoP 静音标记相位
    let levelL = Atomic<Int>(0)  // VU 电平 0...1000（喂数据线程写入，UI 读取）
    let levelR = Atomic<Int>(0)

    /// 当前输出采样率：DSD 源为 DoP 载波或转换后 PCM 率；PCM 源为文件原生率
    private func outputRate(for src: AudioSource) -> Int {
        switch src {
        case .pcm: return Int(src.info.dsdSampleRate)
        case .dsd: return outputMode == .dop ? Int(src.info.dsdSampleRate) / 16 : pcmRate(for: src.info)
        }
    }

    // MARK: 加载

    func load(url: URL) throws {
        if PCMFile.isSupported(url) {
            try load(source: AudioSource.pcm(PCMFile.open(url)))
        } else {
            try load(source: DSDFile.open(url))
        }
    }

    /// 兼容入口：直接加载 DSD 源（旧调用方/测试）
    func load(source src: DSDSource) throws {
        try load(source: AudioSource.dsd(src))
    }

    func load(source src: AudioSource) throws {
        stop()
        feederLock.lock()
        source = src
        let info = src.info
        carrierRate.store(outputRate(for: src), ordering: .relaxed)
        let carrier = outputRate(for: src)
        totalFrames.store(Int(info.durationSeconds * Double(carrier)), ordering: .relaxed)
        let pcm = effectiveMode == .pcm
        modeIsPCM.store(pcm, ordering: .relaxed)
        pcmConverter = nil
        if case .dsd = src, pcm {
            pcmConverter = DSDToPCM(dsdRate: info.dsdSampleRate,
                                    pcmRate: pcmRate(for: info),
                                    channels: info.channelCount)
        }
        channels.store(info.channelCount, ordering: .relaxed)
        feederOffset.store(0, ordering: .relaxed)
        renderedFrames.store(0, ordering: .relaxed)
        trackStartFrames.store(0, ordering: .relaxed)
        pendingBoundary.store(-1, ordering: .relaxed)
        pendingNext = nil
        eofReached.store(false, ordering: .relaxed)
        ring.clear()
        encoder.reset()
        feederLock.unlock()
        state = .stopped
    }

    // MARK: 播放控制

    func play(device: AudioDeviceID) throws {
        guard let src = source else { return }
        let eff = effectiveMode
        if state == .paused {
            // 恢复播放：重新独占并配置设备（暂停期间其他应用可能改过格式）
            if eff == .dop {
                let carrier = Double(outputRate(for: src))
                AudioDeviceManager.acquireHogMode(device)
                try AudioDeviceManager.configureDevice(device, carrierRate: carrier,
                                                       bitPerfect: true)
            } else if matchDeviceRate {
                applyMatchedRate(device: device, rate: Double(outputRate(for: src)))
            }
            deviceID = device
            if let au = audioUnit { AudioOutputUnitStart(au) }
            state = .playing
            return
        }
        if state == .playing { return }

        let carrier = Double(outputRate(for: src))
        if eff == .dop {
            // DoP 位元直通：独占设备并强制匹配格式
            AudioDeviceManager.acquireHogMode(device)
            try AudioDeviceManager.configureDevice(device, carrierRate: carrier,
                                                   bitPerfect: true)
        } else if matchDeviceRate {
            // PCM 匹配模式：设备支持时切换名义采样率，避免 HAL 重采样
            applyMatchedRate(device: device, rate: carrier)
        }
        // PCM 模式：不动设备格式（蓝牙等设备不能承受高速率），HAL 自动重采样
        deviceID = device
        try setupAudioUnit(device: device, carrier: carrier, channels: src.info.channelCount)

        feederLock.lock()
        renderedFrames.store(0, ordering: .relaxed)
        trackStartFrames.store(0, ordering: .relaxed)
        feederOffset.store(0, ordering: .relaxed)
        eofReached.store(false, ordering: .relaxed)
        ring.clear()
        encoder.reset()
        silencePhase.store(0, ordering: .relaxed)
        // 开播防爆音：DoP 先送 10ms 静音（同时让 DAC 提前锁定标记），PCM 做 10ms 渐入
        if eff == .dop {
            pendingSilenceFrames.store(Int(carrier / 100), ordering: .relaxed)
        } else {
            fadeInSamples.store(Int(carrier / 100) * src.info.channelCount, ordering: .relaxed)
        }
        feederLock.unlock()

        startFeeder()
        // 预缓冲 ~100ms，降低开跑即欠载概率
        let prefillSamples = src.info.channelCount * Int(carrier) / 10
        while ring.availableToRead < prefillSamples,
              !eofReached.load(ordering: .relaxed) {
            Thread.sleep(forTimeInterval: 0.005)
        }

        let err = AudioOutputUnitStart(audioUnit!)
        guard err == noErr else { throw DSDError.outputDevice("Failed to start audio output (\(err))") }
        state = .playing
    }

    func pause() {
        guard state == .playing, let au = audioUnit else { return }
        AudioOutputUnitStop(au)
        // 暂停即释放设备独占，让其他应用可以使用 DAC；恢复播放时重新配置
        if deviceID != 0 {
            AudioDeviceManager.releaseHogMode(deviceID)
            AudioDeviceManager.restoreVolume(deviceID)   // 恢复 DoP 强制 1.0 前的音量
        }
        restoreMatchedRate()   // PCM 匹配模式恢复原设备速率
        state = .paused
    }

    func seek(toSeconds seconds: Double) {
        guard let src = source, state == .playing || state == .paused else { return }
        let carrier = Double(carrierRate.load(ordering: .relaxed))
        let frame = max(0, min(Int64(seconds * carrier), Int64(totalFrames.load(ordering: .relaxed))))
        // 读位置语义随源种类：DSD 为每声道字节偏移，PCM 为帧偏移
        let byteOffset: UInt64
        if src.info.isPCM {
            byteOffset = UInt64(max(0, seconds)) * UInt64(src.info.dsdSampleRate)
        } else {
            byteOffset = UInt64(max(0, seconds)) * UInt64(src.info.dsdSampleRate) / 8
        }

        feederLock.lock()
        let wasPlaying = state == .playing
        if wasPlaying, let au = audioUnit { AudioOutputUnitStop(au) }
        ring.clear()
        encoder.reset()
        pcmConverter = nil
        if case .dsd(let dsd) = src, effectiveMode == .pcm {
            pcmConverter = DSDToPCM(dsdRate: dsd.info.dsdSampleRate,
                                    pcmRate: pcmRate(for: dsd.info),
                                    channels: dsd.info.channelCount)
        }
        feederOffset.store(byteOffset, ordering: .relaxed)
        eofReached.store(false, ordering: .relaxed)
        // 保持渲染帧坐标单调：只平移曲目起点，使位置 = frame/carrier
        trackStartFrames.store(renderedFrames.load(ordering: .relaxed) - Int(frame),
                               ordering: .relaxed)
        pendingBoundary.store(-1, ordering: .relaxed)
        silencePhase.store(0, ordering: .relaxed)
        // seek 边界防爆音
        if effectiveMode == .dop {
            pendingSilenceFrames.store(Int(carrier / 100), ordering: .relaxed)
        } else {
            fadeInSamples.store(Int(carrier / 100) * src.info.channelCount, ordering: .relaxed)
        }
        feederLock.unlock()

        if wasPlaying, let au = audioUnit { AudioOutputUnitStart(au) }
    }

    func stop() {
        feederCancel.store(true, ordering: .relaxed)
        feederLock.lock()   // 等待在途读写完
        feederLock.unlock()
        feederThread = nil
        if let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            audioUnit = nil
        }
        if deviceID != 0 {
            AudioDeviceManager.releaseHogMode(deviceID)
            AudioDeviceManager.restoreVolume(deviceID)   // 恢复 DoP 强制 1.0 前的音量
            deviceID = 0
        }
        restoreMatchedRate()   // PCM 匹配模式恢复原设备速率
        ring.clear()
        if source != nil { state = .stopped }
    }

    var positionSeconds: Double {
        let carrier = Double(carrierRate.load(ordering: .relaxed))
        guard carrier > 0 else { return 0 }
        return Double(renderedFrames.load(ordering: .relaxed)
                      - trackStartFrames.load(ordering: .relaxed)) / carrier
    }

    // MARK: 无缝切歌

    /// 预排下一首；规格（采样率/声道/源种类）与当前不同则不保留，播完时走完整重开链路
    func setNext(_ src: AudioSource?) {
        feederLock.lock()
        if let src, let cur = source,
           src.seamlessKey == cur.seamlessKey {
            pendingNext = src
            // 喂数据线程可能已在 EOF 等待（短曲目整个进了缓冲区）——唤醒它走无缝续播
            eofReached.store(false, ordering: .relaxed)
        } else {
            pendingNext = nil
        }
        feederLock.unlock()
    }

    /// 兼容入口：直接预排 DSD 源
    func setNext(_ src: DSDSource?) {
        setNext(src.map { AudioSource.dsd($0) })
    }

    /// 无缝切换到同规格曲目（播放/暂停中有效）；规格不符返回 false，调用方走完整重开
    func switchTrack(_ src: AudioSource) -> Bool {
        guard state == .playing || state == .paused,
              let cur = source,
              src.seamlessKey == cur.seamlessKey else { return false }
        let carrier = Double(carrierRate.load(ordering: .relaxed))
        feederLock.lock()
        source = src
        pendingNext = nil
        feederOffset.store(0, ordering: .relaxed)
        eofReached.store(false, ordering: .relaxed)
        ring.clear()
        totalFrames.store(Int(src.info.durationSeconds * carrier), ordering: .relaxed)
        // 新曲目从当前渲染位置起算（ring 已清空）
        trackStartFrames.store(renderedFrames.load(ordering: .relaxed), ordering: .relaxed)
        pendingBoundary.store(-1, ordering: .relaxed)
        if effectiveMode == .dop {
            pendingSilenceFrames.store(Int(carrier / 100), ordering: .relaxed)
        } else {
            fadeInSamples.store(Int(carrier / 100) * src.info.channelCount, ordering: .relaxed)
        }
        feederLock.unlock()
        return true
    }

    /// 兼容入口：直接切换 DSD 源
    @discardableResult
    func switchTrack(_ src: DSDSource) -> Bool {
        switchTrack(AudioSource.dsd(src))
    }

    // MARK: AUHAL

    private func setupAudioUnit(device: AudioDeviceID, carrier: Double, channels ch: Int) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw DSDError.outputDevice("Audio output component not found")
        }
        var au: AudioUnit?
        var err = AudioComponentInstanceNew(comp, &au)
        guard err == noErr, let unit = au else {
            throw DSDError.outputDevice("Failed to create audio unit (\(err))")
        }

        var dev = device
        err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &dev,
                                   UInt32(MemoryLayout<AudioDeviceID>.size))
        guard err == noErr else {
            AudioComponentInstanceDispose(unit)
            throw DSDError.outputDevice("Failed to bind output device (\(err))")
        }

        // 应用侧格式：交错 Int32，24-bit DoP 左对齐进 32-bit 容器
        var fmt = AudioStreamBasicDescription(
            mSampleRate: carrier,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * UInt32(ch),
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * UInt32(ch),
            mChannelsPerFrame: UInt32(ch),
            mBitsPerChannel: 32,
            mReserved: 0)
        err = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Input, 0, &fmt,
                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard err == noErr else {
            AudioComponentInstanceDispose(unit)
            throw DSDError.outputDevice("Failed to set output format (\(err))")
        }

        var callback = AURenderCallbackStruct(
            inputProc: dopRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        err = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                   kAudioUnitScope_Input, 0, &callback,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard err == noErr else {
            AudioComponentInstanceDispose(unit)
            throw DSDError.outputDevice("Failed to register render callback (\(err))")
        }

        err = AudioUnitInitialize(unit)
        guard err == noErr else {
            AudioComponentInstanceDispose(unit)
            throw DSDError.outputDevice("Failed to initialize audio unit (\(err))")
        }
        audioUnit = unit
    }

    // MARK: 渲染回调（实时线程）

    fileprivate func render(frameCount: Int, ioData: UnsafeMutablePointer<AudioBufferList>) {
        let buf = ioData.pointee.mBuffers
        guard let data = buf.mData else { return }
        let ptr = data.assumingMemoryBound(to: Int32.self)
        let ch = max(1, channels.load(ordering: .relaxed))
        let totalSamples = frameCount * ch

        let got = ring.read(into: ptr, count: totalSamples)
        if got < totalSamples {
            _ = underrunFrames.add(frameCount - got / ch, ordering: .relaxed)
            if modeIsPCM.load(ordering: .relaxed) {
                // PCM 模式：补零
                for i in got..<totalSamples { ptr[i] = 0 }
            } else {
                // DoP 欠载：补静音并保持标记相位连续（无分配，实时线程安全）
                var phase = silencePhase.load(ordering: .relaxed)
                var i = got
                while i < totalSamples {
                    let marker: UInt32 = phase == 0 ? 0x05 : 0xFA
                    let word = Int32(bitPattern: (marker << 24) | (0x69 << 16) | (0x69 << 8))
                    for _ in 0..<ch { ptr[i] = word; i += 1 }
                    phase ^= 1
                }
                silencePhase.store(phase, ordering: .relaxed)
            }
        }
        // 记录真实数据的标记相位，供欠载静音延续
        if got >= ch, !modeIsPCM.load(ordering: .relaxed) {
            let w = UInt32(bitPattern: ptr[got - ch])
            silencePhase.store((w >> 24) == 0x05 ? 1 : 0, ordering: .relaxed)
        }
        // VU 电平（按实际渲染位置计算，与听觉同步）
        if got > 0 {
            let isPCM = modeIsPCM.load(ordering: .relaxed)
            let (l, r) = isPCM
                ? estimateLevelsPCM(ptr, count: got, channels: ch)
                : estimateLevelsDoP(ptr, count: got, channels: ch)
            levelL.store(Int(l * 1000), ordering: .relaxed)
            levelR.store(Int(r * 1000), ordering: .relaxed)
        }
        // 无缝切换边界：渲染越过后才提交新曲目起点并通知（UI 与听觉同步）
        let newRendered = renderedFrames.add(got / ch, ordering: .relaxed).newValue
        let pb = pendingBoundary.load(ordering: .relaxed)
        if pb >= 0, newRendered >= pb {
            pendingBoundary.store(-1, ordering: .relaxed)
            trackStartFrames.store(pb, ordering: .relaxed)
            totalFrames.store(pendingTrackFrames.load(ordering: .relaxed), ordering: .relaxed)
            let cb = onTrackAdvanced
            DispatchQueue.main.async { cb?() }
        }
    }

    // MARK: 喂数据线程

    private func startFeeder() {
        feederCancel.store(false, ordering: .relaxed)
        let thread = Thread { [weak self] in self?.feederLoop() }
        thread.qualityOfService = .userInitiated
        thread.name = "DSDFeeder"
        feederThread = thread
        thread.start()
    }

    private func feederLoop() {
        let chunkFrames = 16384
        while !feederCancel.load(ordering: .relaxed) {
            feederLock.lock()
            if feederCancel.load(ordering: .relaxed) { feederLock.unlock(); return }
            guard let src = source else { feederLock.unlock(); return }
            let ch = src.info.channelCount
            let freeFrames = ring.availableToWrite / ch
            guard freeFrames >= chunkFrames else {
                feederLock.unlock()
                // 按剩余空间比例休眠（最多消耗剩余空间的一半），避免 2ms 轮询空转：
                // 环形缓冲容量是秒级的，播放中无需高频醒来检查
                let carrier = Double(max(1, carrierRate.load(ordering: .relaxed)))
                let sleepSec = min(0.05, max(0.002, Double(freeFrames) / carrier * 0.5))
                Thread.sleep(forTimeInterval: sleepSec)
                continue
            }

            // 边界静音（DoP 防爆音），优先于新数据
            let sil = pendingSilenceFrames.load(ordering: .relaxed)
            if sil > 0 {
                let n = min(sil, chunkFrames)
                let written = ring.write(encoder.silence(frames: n, channels: ch))
                _ = pendingSilenceFrames.add(-(written / ch), ordering: .relaxed)
                feederLock.unlock()
                continue
            }

            do {
                let off = feederOffset.load(ordering: .relaxed)
                // 边界渐入（PCM 防爆音），DSD→PCM 转换与 PCM 直出共用
                func applyFade(_ s: inout [Int32]) {
                    let fade = fadeInSamples.load(ordering: .relaxed)
                    guard fade > 0, !s.isEmpty else { return }
                    let n = min(fade, s.count)
                    for i in 0..<n {
                        s[i] = Int32(Int64(s[i]) * Int64(i) / Int64(n))
                    }
                    _ = fadeInSamples.add(-n, ordering: .relaxed)
                }
                // 按源种类读取：DSD 读字节后编码/转换，PCM 直接读采样；units = 进度步长
                var samples = [Int32]()
                var units: UInt64 = 0
                switch src {
                case .dsd(let dsd):
                    let dsdBytes = try dsd.read(channelByteOffset: off, perChannelByteCount: chunkFrames * 2)
                    if !dsdBytes.isEmpty {
                        units = UInt64(dsdBytes.count / ch)
                        if let conv = pcmConverter {
                            samples = conv.process(dsdBytes, channels: ch)
                        } else {
                            samples = encoder.encode(dsdBytes, channels: ch)
                        }
                        applyFade(&samples)
                    }
                case .pcm(let pcm):
                    let frames = try pcm.read(frameOffset: off, frameCount: chunkFrames)
                    if !frames.isEmpty {
                        units = UInt64(frames.count / ch)
                        samples = frames
                        applyFade(&samples)
                    }
                }
                guard units > 0 else {
                    // 无缝续播：有预排的下一首（规格已由 setNext 保证一致）
                    if let next = pendingNext {
                        pendingNext = nil
                        source = next
                        feederOffset.store(0, ordering: .relaxed)
                        let carrier = carrierRate.load(ordering: .relaxed)
                        let gap = carrier / 200   // 5ms 边界静音
                        if effectiveMode == .dop {
                            pendingSilenceFrames.store(gap, ordering: .relaxed)
                        } else {
                            fadeInSamples.store(gap * ch, ordering: .relaxed)
                        }
                        // 边界先挂起，渲染真正越过该帧时才生效并通知（保证 UI 与听觉同步）
                        let boundary = renderedFrames.load(ordering: .relaxed)
                            + ring.availableToRead / ch
                            + (effectiveMode == .dop ? gap : 0)
                        pendingTrackFrames.store(Int(next.info.durationSeconds * Double(carrier)),
                                                 ordering: .relaxed)
                        pendingBoundary.store(boundary, ordering: .relaxed)
                        feederLock.unlock()
                        continue
                    }
                    eofReached.store(true, ordering: .relaxed)
                    feederLock.unlock()
                    // 等待环形缓冲播完；期间发生 seek（eof 被清除）则回到主循环
                    while !feederCancel.load(ordering: .relaxed),
                          eofReached.load(ordering: .relaxed),
                          ring.availableToRead > 0 {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    if feederCancel.load(ordering: .relaxed) { return }
                    if !eofReached.load(ordering: .relaxed) { continue }
                    state = .finished
                    return
                }
                feederOffset.store(off + units, ordering: .relaxed)
                _ = ring.write(samples)
                feederLock.unlock()
            } catch {
                feederLock.unlock()
                let cb = onError
                DispatchQueue.main.async { cb?("Failed to read file: \(error.localizedDescription)") }
                return
            }
        }
    }
}

// MARK: - C 渲染回调桥

private func dopRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData else { return noErr }
    let engine = Unmanaged<PlaybackEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    engine.render(frameCount: Int(inNumberFrames), ioData: ioData)
    return noErr
}
