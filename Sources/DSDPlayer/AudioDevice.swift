import CoreAudio
import Foundation

struct OutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String   // 持久 UID：重枚举（睡眠唤醒/重插）后不变，用于重新匹配设备
    let name: String
    let isUSB: Bool
    let supportedRates: [Double]  // 名义采样率范围（取各范围端点并集）

    func supports(rate: Double) -> Bool {
        supportedRates.contains { $0 == rate }
    }
}

enum AudioDeviceError: Error, LocalizedError {
    case noSupportedFormat(Double)
    case setRateFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noSupportedFormat(let r):
            return "Device doesn't support \(Int(r)) Hz / 24-bit+ output required for this DoP stream"
        case .setRateFailed(let s):
            return "Failed to set device sample rate (OSStatus \(s))"
        }
    }
}

enum AudioDeviceManager {

    // MARK: 枚举输出设备

    static func outputDevices() -> [OutputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            guard outputStreamCount(id) > 0 else { return nil }
            return OutputDevice(id: id,
                                uid: deviceUID(id),
                                name: deviceName(id),
                                isUSB: transportType(id) == kAudioDeviceTransportTypeUSB,
                                supportedRates: availableRates(id))
        }
    }

    // MARK: 设备列表变更监听（拔插 / 睡眠唤醒重枚举时通知）

    private nonisolated(unsafe) static var deviceListenerInstalled = false

    /// 注册设备列表变更回调（主线程派发），只安装一次
    static func installDeviceChangeListener(_ callback: @escaping () -> Void) {
        guard !deviceListenerInstalled else { return }
        deviceListenerInstalled = true
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &addr, DispatchQueue.main) { _, _ in
            callback()
        }
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown
        else { return nil }
        return id
    }

    private static func outputStreamCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func deviceName(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return "Device \(id)" }
        return name as String
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return "\(id)" }
        return uid as String
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func availableRates(_ id: AudioDeviceID) -> [Double] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: count)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        var rates = Set<Double>()
        for r in ranges {
            if r.mMinimum == r.mMaximum { rates.insert(r.mMinimum) }
            else {
                // 连续范围：取常见离散值
                for c in [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000, 1411200.0] {
                    if c >= r.mMinimum && c <= r.mMaximum { rates.insert(c) }
                }
            }
        }
        return rates.sorted()
    }

    // MARK: 采样率 / 物理格式

    /// 将设备输出流设置为指定的采样率与 >=24bit 整型物理格式。
    /// bitPerfect 时（DoP）强制音量 1.0 并取消静音，保证位元不被 HAL 改动。
    static func configureDevice(_ device: AudioDeviceID, carrierRate: Double,
                                bitPerfect: Bool = true) throws {
        tlog("DEVICE configureDevice carrier=\(carrierRate)")
        guard let streamID = firstOutputStream(device) else {
            throw AudioDeviceError.noSupportedFormat(carrierRate)
        }

        // 在物理格式中寻找匹配采样率、位深 >= 24 的整型格式
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(streamID, &addr, 0, nil, &size)
        guard status == noErr else { throw AudioDeviceError.setRateFailed(status) }
        let count = Int(size) / MemoryLayout<AudioStreamRangedDescription>.size
        var formats = [AudioStreamRangedDescription](
            repeating: AudioStreamRangedDescription(), count: count)
        status = AudioObjectGetPropertyData(streamID, &addr, 0, nil, &size, &formats)
        guard status == noErr else { throw AudioDeviceError.setRateFailed(status) }

        let candidates = formats.filter { f in
            let d = f.mFormat
            guard d.mFormatID == kAudioFormatLinearPCM else { return false }
            // DoP 位元直通要求 >=24bit 整型；PCM 模式接受浮点等任意格式（HAL 负责转换）
            if bitPerfect {
                guard d.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
                      d.mBitsPerChannel >= 24 else { return false }
            }
            return f.mSampleRateRange.mMinimum <= carrierRate && carrierRate <= f.mSampleRateRange.mMaximum
        }
        // 优先完全等采样率的离散格式
        guard let exact = candidates.first(where: {
            $0.mSampleRateRange.mMinimum == carrierRate && $0.mSampleRateRange.mMaximum == carrierRate
        }) ?? candidates.first else {
            if bitPerfect { throw AudioDeviceError.noSupportedFormat(carrierRate) }
            // PCM 模式找不到匹配采样率：不强求，交给 HAL 重采样
            var fallbackRate = carrierRate
            var fallbackAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            if AudioObjectHasProperty(device, &fallbackAddr) {
                AudioObjectSetPropertyData(device, &fallbackAddr, 0, nil,
                                           UInt32(MemoryLayout<Float64>.size), &fallbackRate)
            }
            return
        }

        var newFormat = exact.mFormat
        newFormat.mSampleRate = carrierRate
        var setAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0)
        status = AudioObjectSetPropertyData(device, &setAddr, 0, nil,
                                            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &newFormat)
        guard status == noErr else { throw AudioDeviceError.setRateFailed(status) }

        // 再显式设置名义采样率（部分设备需要）
        var rate = carrierRate
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &rateAddr) {
            AudioObjectSetPropertyData(device, &rateAddr, 0, nil,
                                       UInt32(MemoryLayout<Float64>.size), &rate)
        }

        guard bitPerfect else { return }   // PCM 模式下保留用户音量设置
        forceBitPerfectVolume(device)
    }

    // MARK: 音量保存 / 恢复（DoP 强制 1.0 后恢复原音量）

    // 仅从主线程的 play/pause/stop 路径访问，无并发写
    private nonisolated(unsafe) static var savedVolumes: [AudioDeviceID: [(UInt32, Float32)]] = [:]

    /// DoP 要求位元直通：设备音量必须为 1.0 且取消静音，
    /// 否则 HAL 的音量乘法/静音会破坏标记字节，DAC 无法进入 DSD 模式。
    /// 修改前保存原音量，供 restoreVolume 恢复。
    private static func forceBitPerfectVolume(_ device: AudioDeviceID) {
        var saved: [(UInt32, Float32)] = []
        for element: UInt32 in [0, 1, 2] {
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            if AudioObjectHasProperty(device, &volAddr) {
                var cur = Float32(1)
                var sz = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(device, &volAddr, 0, nil, &sz, &cur) == noErr {
                    saved.append((element, cur))
                }
                var one = Float32(1.0)
                AudioObjectSetPropertyData(device, &volAddr, 0, nil,
                                           UInt32(MemoryLayout<Float32>.size), &one)
            }
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            if AudioObjectHasProperty(device, &muteAddr) {
                var zero = UInt32(0)
                AudioObjectSetPropertyData(device, &muteAddr, 0, nil,
                                           UInt32(MemoryLayout<UInt32>.size), &zero)
            }
        }
        if !saved.isEmpty { savedVolumes[device] = saved }
    }

    /// 恢复进入 DoP 前保存的音量（stop/pause 时调用）
    static func restoreVolume(_ device: AudioDeviceID) {
        guard let saved = savedVolumes.removeValue(forKey: device) else { return }
        for (element, value) in saved {
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            var v = value
            AudioObjectSetPropertyData(device, &volAddr, 0, nil,
                                       UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    private static func firstOutputStream(_ device: AudioDeviceID) -> AudioStreamID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams) == noErr else { return nil }
        return streams.first
    }

    // MARK: Hog Mode（独占设备，防止其他进程改动格式）

    static func acquireHogMode(_ device: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &addr) else { return }
        var owner = pid_t(-1)
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &owner) == noErr else { return }
        if owner == -1 {
            var me = getpid()
            AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<pid_t>.size), &me)
        }
    }

    static func releaseHogMode(_ device: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &addr) else { return }
        var owner = pid_t(-1)
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &owner) == noErr else { return }
        if owner == getpid() {
            var releaseVal = pid_t(-1)
            AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<pid_t>.size), &releaseVal)
        }
    }
}
