import AVFoundation
import Foundation

// MARK: - PCM 数据源（WAV / FLAC）

/// PCM 采样源：read 返回按 [L R L R ...] 交错、32-bit 有符号整型采样
/// （满幅映射到 Int32 全量程，与引擎 PCM 通路一致）
protocol PCMSource: AnyObject {
    var info: DSDInfo { get }   // isPCM = true
    func read(frameOffset: UInt64, frameCount: Int) throws -> [Int32]
}

enum PCMFile {
    static let extensions = ["wav", "flac"]

    static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static func open(_ url: URL) throws -> PCMSource {
        try AVPCMFile(url: url)
    }
}

/// WAV/FLAC 统一实现：元数据手工解析文件头（拿原始位深），
/// 音频帧读取走 AVAudioFile（系统 CoreAudio 解码 FLAC，输出 float32）
final class AVPCMFile: PCMSource {
    let info: DSDInfo

    private let file: AVAudioFile
    private let readLock = NSLock()   // AVAudioFile 的 framePosition/read 非线程安全

    init(url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let meta: (rate: UInt32, channels: Int, bits: Int)
        switch ext {
        case "wav":  meta = try Self.parseWAVHeader(url)
        case "flac": meta = try Self.parseFlacStreamInfo(url)
        default: throw DSDError.unsupportedFormat(ext.isEmpty ? url.lastPathComponent : ".\(ext)")
        }
        guard meta.channels == 1 || meta.channels == 2 else {
            throw DSDError.unsupportedChannels(meta.channels)
        }
        guard meta.rate > 0 else {
            throw DSDError.unsupportedSampleRate(meta.rate)
        }
        guard let af = try? AVAudioFile(forReading: url) else {
            throw DSDError.corruptFile(url.lastPathComponent)
        }
        file = af
        // 优先使用头解析的精确参数；总帧数取 AVAudioFile（它处理填充/截断更稳）
        info = DSDInfo(formatName: ext.uppercased(),
                       dsdSampleRate: meta.rate,
                       channelCount: meta.channels,
                       totalSamplesPerChannel: UInt64(max(af.length, 0)),
                       isPCM: true, bitDepth: meta.bits)
    }

    // MARK: 采样读取

    func read(frameOffset: UInt64, frameCount: Int) throws -> [Int32] {
        let total = UInt64(max(file.length, 0))
        guard frameOffset < total, frameCount > 0 else { return [] }
        readLock.lock()
        defer { readLock.unlock() }
        file.framePosition = Int64(frameOffset)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw DSDError.corruptFile("无法分配音频缓冲")
        }
        do {
            try file.read(into: buf)
        } catch {
            // EOF 附近短读是正常情况；真正的损坏在 init 时已拦截
            if buf.frameLength == 0 { return [] }
        }
        let n = Int(buf.frameLength)
        let ch = Int(buf.format.channelCount)
        var out = [Int32]()
        out.reserveCapacity(n * ch)
        if let f = buf.floatChannelData {
            let scale = Float(Int32.max)
            for i in 0..<n {
                for c in 0..<ch {
                    let v = f[c][i] * scale
                    out.append(Int32(v.clamped(to: Float(Int32.min)...Float(Int32.max))))
                }
            }
        }
        return out
    }

    // MARK: WAV 头解析（RIFF/WAVE，fmt chunk）

    /// 解析 fmt chunk：返回 (采样率, 声道数, 位深)。支持 PCM 整型(1) 与 IEEE float(3)，含 WAVE_FORMAT_EXTENSIBLE(0xFFFE)
    static func parseWAVHeader(_ url: URL) throws -> (rate: UInt32, channels: Int, bits: Int) {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let h = try fh.readAt(0, count: 12)
        guard h.count == 12,
              h[0] == 0x52, h[1] == 0x49, h[2] == 0x46, h[3] == 0x46,   // "RIFF"
              h[8] == 0x57, h[9] == 0x41, h[10] == 0x56, h[11] == 0x45 // "WAVE"
        else { throw DSDError.unsupportedFormat(url.lastPathComponent) }

        var offset: UInt64 = 12
        var rate: UInt32 = 0, channels: Int = 0, bits: Int = 0
        let fileSize = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: 12)

        while offset + 8 <= fileSize {
            let hdr = try fh.readAt(offset, count: 8)
            guard hdr.count == 8 else { break }
            let id = String(decoding: hdr[0..<4], as: UTF8.self)
            let size = Data(hdr).u32le(4)
            if id == "fmt " {
                let b = try fh.readAt(offset + 8, count: Int(size))
                guard b.count >= 16 else { throw DSDError.corruptFile("WAV fmt chunk 过短") }
                let format = Data(b).u16le(0)
                channels = Int(Data(b).u16le(2))
                rate = Data(b).u32le(4)
                bits = Int(Data(b).u16le(14))
                if format == 0xFFFE, b.count >= 40 {
                    // 扩展头：ValidBits(2) + ChannelMask(4) + SubFormat GUID(16)
                    let sub = Data(b).u16le(24)
                    if sub == 1 || sub == 3 { /* 接受 PCM/float 子格式 */ }
                    else { throw DSDError.unsupportedFormat("WAV sub-format \(sub)") }
                } else if format != 1 && format != 3 {
                    throw DSDError.unsupportedFormat("WAV format code \(format)")
                }
                break
            }
            offset += 8 + UInt64(size) + UInt64(size & 1)
        }
        guard rate > 0, channels > 0, bits > 0 else {
            throw DSDError.corruptFile("WAV 缺少 fmt chunk")
        }
        return (rate, channels, bits)
    }

    // MARK: FLAC STREAMINFO 解析

    /// 解析 fLaC 头 + STREAMINFO 元数据块：返回 (采样率, 声道数, 位深)
    static func parseFlacStreamInfo(_ url: URL) throws -> (rate: UInt32, channels: Int, bits: Int) {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let h = try fh.readAt(0, count: 4)
        guard h.count == 4, h[0] == 0x66, h[1] == 0x4C, h[2] == 0x61, h[3] == 0x43 // "fLaC"
        else { throw DSDError.unsupportedFormat(url.lastPathComponent) }

        var offset: UInt64 = 4
        var isLast = false
        while !isLast {
            let hdr = try fh.readAt(offset, count: 4)
            guard hdr.count == 4 else { throw DSDError.corruptFile("FLAC 元数据块头缺失") }
            isLast = (hdr[0] & 0x80) != 0
            let type = hdr[0] & 0x7F
            let size = UInt64(hdr[1]) << 16 | UInt64(hdr[2]) << 8 | UInt64(hdr[3])
            if type == 0 {   // STREAMINFO，固定 34 字节
                let b = try fh.readAt(offset + 4, count: 34)
                guard b.count == 34 else { throw DSDError.corruptFile("FLAC STREAMINFO 过短") }
                let v = Data(b).u64be(10)   // 偏移 10 起 8 字节打包域
                let rate = UInt32((v >> 44) & 0xFFFFF)      // 20 bits
                let ch = Int((v >> 41) & 0x7) + 1           // 3 bits（存 n-1）
                let bits = Int((v >> 36) & 0x1F) + 1        // 5 bits（存 n-1）
                guard rate > 0 else { throw DSDError.corruptFile("FLAC 采样率为 0") }
                return (rate, ch, bits)
            }
            offset += 4 + size
        }
        throw DSDError.corruptFile("FLAC 缺少 STREAMINFO")
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
