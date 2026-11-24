import Foundation

enum DSDError: Error, LocalizedError {
    case unsupportedFormat(String)
    case corruptFile(String)
    case unsupportedChannels(Int)
    case unsupportedSampleRate(UInt32)
    case dstCompressed
    case outputDevice(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let s): return "Unsupported file format: \(s)"
        case .corruptFile(let s): return "File is corrupt or unparseable: \(s)"
        case .unsupportedChannels(let n): return "\(n) channels not supported (mono/stereo only)"
        case .unsupportedSampleRate(let r): return "Unsupported DSD sample rate: \(r) Hz"
        case .dstCompressed: return "DST-compressed DFF files are not supported"
        case .outputDevice(let s): return "Output device error: \(s)"
        }
    }
}

struct DSDInfo: Hashable {
    let formatName: String              // "DSF" / "DFF" / "SACD" / "WAV" / "FLAC"
    let dsdSampleRate: UInt32           // DSD: 2822400 ...；PCM: 原生采样率（44100/96000 ...）
    let channelCount: Int
    let totalSamplesPerChannel: UInt64  // DSD: 单位 bit；PCM: 单位 frame（durationSeconds 公式不变）
    var isPCM: Bool = false             // PCM 源（WAV/FLAC）：只能走 PCM 输出，无 DoP
    var bitDepth: Int = 0               // PCM 位深（16/24/32），DSD 源为 0

    var durationSeconds: Double { Double(totalSamplesPerChannel) / Double(dsdSampleRate) }
    var dopCarrierRate: Double { Double(dsdSampleRate) / 16.0 }
    var dsdMultiple: Int { Int(dsdSampleRate / 44100) }

    /// 播放列表徽标文本：DSD 显示倍数（DSD64），PCM 显示格式名（WAV/FLAC）
    var badgeText: String { isPCM ? formatName : "DSD\(dsdMultiple)" }
    /// PCM 源显示用的采样率文本，如 "44.1kHz" / "96kHz"
    var pcmRateText: String {
        let k = Double(dsdSampleRate) / 1000
        return k.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(k))kHz" : String(format: "%.1fkHz", k)
    }
}

/// 统一的 DSD 数据源。read 返回按 [ch0b0, ch1b0, ch0b1, ch1b1, ...] 交错、
/// 每字节已规范化为 MSB-first（DoP 可直接打包）的 DSD 字节流。
protocol DSDSource: AnyObject {
    var info: DSDInfo { get }
    var totalBytesPerChannel: UInt64 { get }
    func read(channelByteOffset: UInt64, perChannelByteCount: Int) throws -> [UInt8]
}

enum DSDFile {
    static func open(_ url: URL) throws -> DSDSource {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "dsf": return try DSFFile(url: url)
        case "dff": return try DFFFile(url: url)
        default: throw DSDError.unsupportedFormat(ext.isEmpty ? url.lastPathComponent : ".\(ext)")
        }
    }
}

// MARK: - 工具

let bitReverseLUT: [UInt8] = (0...255).map { v -> UInt8 in
    var x = UInt8(v)
    x = (x & 0x55) << 1 | (x & 0xAA) >> 1
    x = (x & 0x33) << 2 | (x & 0xCC) >> 2
    return (x << 4) | (x >> 4)
}

extension Data {
    func u16le(_ off: Int) -> UInt16 {
        UInt16(self[off]) | UInt16(self[off + 1]) << 8
    }
    func u32le(_ off: Int) -> UInt32 {
        UInt32(self[off]) | UInt32(self[off + 1]) << 8 | UInt32(self[off + 2]) << 16 | UInt32(self[off + 3]) << 24
    }
    func u64le(_ off: Int) -> UInt64 {
        UInt64(u32le(off)) | UInt64(u32le(off + 4)) << 32
    }
    func u16be(_ off: Int) -> UInt16 {
        UInt16(self[off]) << 8 | UInt16(self[off + 1])
    }
    func u32be(_ off: Int) -> UInt32 {
        UInt32(self[off]) << 24 | UInt32(self[off + 1]) << 16 | UInt32(self[off + 2]) << 8 | UInt32(self[off + 3])
    }
    func u64be(_ off: Int) -> UInt64 {
        UInt64(u32be(off)) << 32 | UInt64(u32be(off + 4))
    }
}

extension FileHandle {
    func readAt(_ offset: UInt64, count: Int) throws -> [UInt8] {
        try seek(toOffset: offset)
        let data = try read(upToCount: count) ?? Data()
        return [UInt8](data)
    }
}

// MARK: - DSF (Sony, 小端, 块交错, LSB-first)

final class DSFFile: DSDSource {
    let info: DSDInfo
    let totalBytesPerChannel: UInt64

    private let file: FileHandle
    private let blockSize: UInt64      // 每声道每块字节数 (通常 4096)
    private let dataStart: UInt64      // data chunk 负载起始文件偏移
    private let dataPayloadSize: UInt64

    init(url: URL) throws {
        let fh = try FileHandle(forReadingFrom: url)
        file = fh

        let header = try fh.readAt(0, count: 28)
        guard header.count == 28,
              header[0] == 0x44, header[1] == 0x53, header[2] == 0x44, header[3] == 0x20 // "DSD "
        else { throw DSDError.unsupportedFormat(url.lastPathComponent) }

        var offset: UInt64 = 28
        var channels = 0, rate: UInt32 = 0, sampleCount: UInt64 = 0, block: UInt64 = 0
        var dStart: UInt64 = 0, dPayload: UInt64 = 0
        var sawFmt = false, sawData = false

        while !sawData {
            let hdr = try fh.readAt(offset, count: 12)
            guard hdr.count == 12 else { throw DSDError.corruptFile("缺少 data chunk") }
            let id = String(decoding: hdr[0..<4], as: UTF8.self)
            let size = Data(hdr).u64le(4)
            guard size >= 12 else { throw DSDError.corruptFile("非法 chunk 大小") }

            if id == "fmt " {
                let body = try fh.readAt(offset + 12, count: Int(size) - 12)
                guard body.count >= 36 else { throw DSDError.corruptFile("fmt chunk 过短") }
                let b = Data(body)
                channels = Int(b.u32le(12))
                rate = b.u32le(16)
                sampleCount = b.u64le(24)
                block = UInt64(b.u32le(32))
                sawFmt = true
            } else if id == "data" {
                dStart = offset + 12
                dPayload = size - 12
                sawData = true
            }
            offset += size
        }

        guard sawFmt, block > 0 else { throw DSDError.corruptFile("缺少 fmt chunk") }
        guard channels == 1 || channels == 2 else { throw DSDError.unsupportedChannels(channels) }
        guard rate == 2_822_400 || rate == 5_644_800 || rate == 11_289_600 || rate == 22_579_200
        else { throw DSDError.unsupportedSampleRate(rate) }

        info = DSDInfo(formatName: "DSF", dsdSampleRate: rate,
                       channelCount: channels, totalSamplesPerChannel: sampleCount)
        totalBytesPerChannel = (sampleCount + 7) / 8
        blockSize = block
        dataStart = dStart
        dataPayloadSize = dPayload
    }

    func read(channelByteOffset off: UInt64, perChannelByteCount n: Int) throws -> [UInt8] {
        let ch = info.channelCount
        var out = [UInt8]()
        out.reserveCapacity(n * ch)
        var pos = off
        var remaining = n

        while remaining > 0 && pos < totalBytesPerChannel {
            let blockIdx = pos / blockSize
            let inBlock = Int(pos % blockSize)
            let take = min(remaining, Int(blockSize) - inBlock, Int(totalBytesPerChannel - pos))

            var slices = [[UInt8]]()
            slices.reserveCapacity(ch)
            for c in 0..<ch {
                let fileOff = dataStart + blockIdx * UInt64(ch) * blockSize
                            + UInt64(c) * blockSize + UInt64(inBlock)
                var bytes = try file.readAt(fileOff, count: take)
                if bytes.count < take {  // 文件尾部填充 DSD 静音
                    bytes += [UInt8](repeating: 0x69, count: take - bytes.count)
                }
                // DSF 为 LSB-first，逐字节反转为 MSB-first 供 DoP 打包
                slices.append(bytes.map { bitReverseLUT[Int($0)] })
            }
            for i in 0..<take {
                for c in 0..<ch { out.append(slices[c][i]) }
            }
            pos += UInt64(take)
            remaining -= take
        }
        return out
    }
}

// MARK: - DFF (Philips DSDIFF, 大端, 字节交错, MSB-first)

final class DFFFile: DSDSource {
    let info: DSDInfo
    let totalBytesPerChannel: UInt64

    private let file: FileHandle
    private let dataStart: UInt64

    init(url: URL) throws {
        let fh = try FileHandle(forReadingFrom: url)
        file = fh

        let header = try fh.readAt(0, count: 16)
        guard header.count == 16,
              header[0] == 0x46, header[1] == 0x52, header[2] == 0x4D, header[3] == 0x38, // "FRM8"
              header[12] == 0x44, header[13] == 0x53, header[14] == 0x44, header[15] == 0x20 // "DSD "
        else { throw DSDError.unsupportedFormat(url.lastPathComponent) }
        let frmSize = Data(header).u64be(4)
        let fileEnd = 16 + frmSize

        var offset: UInt64 = 16
        var channels = 0, rate: UInt32 = 0
        var compressed = false
        var dStart: UInt64 = 0, dPayload: UInt64 = 0
        var sawFS = false, sawData = false

        func parsePropChunk(at propOffset: UInt64, size: UInt64) throws {
            // PROP 负载: "SND " + 属性子块
            var p = propOffset + 4
            let end = propOffset + size
            while p + 12 <= end {
                let hdr = try fh.readAt(p, count: 12)
                guard hdr.count == 12 else { return }
                let id = String(decoding: hdr[0..<4], as: UTF8.self)
                let sz = Data(hdr).u64be(4)
                let bodyStart = p + 12
                if id == "FS  " {
                    let b = try fh.readAt(bodyStart, count: 4)
                    guard b.count == 4 else { throw DSDError.corruptFile("FS chunk 过短") }
                    rate = Data(b).u32be(0)
                    sawFS = true
                } else if id == "CHNL" {
                    let b = try fh.readAt(bodyStart, count: 2)
                    guard b.count == 2 else { throw DSDError.corruptFile("CHNL chunk 过短") }
                    channels = Int(Data(b).u16be(0))
                } else if id == "CMPR" {
                    let b = try fh.readAt(bodyStart, count: 4)
                    guard b.count == 4 else { throw DSDError.corruptFile("CMPR chunk 过短") }
                    let cmpr = String(decoding: b[0..<4], as: UTF8.self)
                    if cmpr != "DSD " { compressed = true }
                }
                p = bodyStart + sz + (sz & 1) // 偶数对齐
            }
        }

        while offset + 12 <= fileEnd && !sawData {
            let hdr = try fh.readAt(offset, count: 12)
            guard hdr.count == 12 else { break }
            let id = String(decoding: hdr[0..<4], as: UTF8.self)
            let size = Data(hdr).u64be(4)
            if id == "PROP" {
                try parsePropChunk(at: offset + 12, size: size)
            } else if id == "DSD " {
                dStart = offset + 12
                dPayload = size
                sawData = true
            }
            offset += 12 + size + (size & 1)
        }

        guard sawData else { throw DSDError.corruptFile("缺少 DSD 声音数据块") }
        guard !compressed else { throw DSDError.dstCompressed }
        guard sawFS, channels > 0 else { throw DSDError.corruptFile("缺少 FS/CHNL 属性") }
        guard channels == 1 || channels == 2 else { throw DSDError.unsupportedChannels(channels) }
        guard rate == 2_822_400 || rate == 5_644_800 || rate == 11_289_600 || rate == 22_579_200
        else { throw DSDError.unsupportedSampleRate(rate) }

        totalBytesPerChannel = dPayload / UInt64(channels)
        info = DSDInfo(formatName: "DFF", dsdSampleRate: rate,
                       channelCount: channels, totalSamplesPerChannel: totalBytesPerChannel * 8)
        dataStart = dStart
    }

    func read(channelByteOffset off: UInt64, perChannelByteCount n: Int) throws -> [UInt8] {
        let ch = info.channelCount
        let avail = totalBytesPerChannel > off ? Int(totalBytesPerChannel - off) : 0
        let take = min(n, avail)
        guard take > 0 else { return [] }
        var bytes = try file.readAt(dataStart + off * UInt64(ch), count: take * ch)
        if bytes.count < take * ch {
            bytes += [UInt8](repeating: 0x69, count: take * ch - bytes.count)
        }
        return bytes
    }
}

// MARK: - 内嵌封面提取（DSF/DFF 均使用 ID3v2 APIC 帧存储封面图片）

enum CoverArt {
    /// 提取封面图片数据：先取文件内嵌 ID3v2 封面，缺失时查找同目录封面图片文件
    static func extract(from url: URL) -> Data? {
        if let ext = url.pathExtension.lowercased() as String?,
           let fh = try? FileHandle(forReadingFrom: url) {
            defer { try? fh.close() }
            if ext == "dsf" {
                if let d = extractFromDSF(fh: fh, url: url) { return d }
            } else if ext == "dff" {
                if let d = extractFromDFF(fh: fh, url: url) { return d }
            } else if ext == "flac" {
                if let d = extractFromFLAC(fh: fh, url: url) { return d }
            }
        }
        return extractFromFolder(url.deletingLastPathComponent())
    }

    /// FLAC：遍历元数据块找 PICTURE 块（type 6），取图片数据负载
    private static func extractFromFLAC(fh: FileHandle, url: URL) -> Data? {
        let fileSize = (try? fh.seekToEnd()) ?? 0
        guard fileSize > 8 else { return nil }
        var offset: UInt64 = 4   // 跳过 "fLaC"
        var isLast = false
        while !isLast, offset + 4 <= fileSize {
            guard let hdr = try? fh.readAt(offset, count: 4), hdr.count == 4 else { return nil }
            isLast = (hdr[0] & 0x80) != 0
            let type = hdr[0] & 0x7F
            let size = UInt64(hdr[1]) << 16 | UInt64(hdr[2]) << 8 | UInt64(hdr[3])
            guard offset + 4 + size <= fileSize else { return nil }
            if type == 6, size > 32,   // PICTURE
               let body = try? fh.readAt(offset + 4, count: Int(size)),
               body.count == size {
                return parseFlacPicture(Data(body))
            }
            offset += 4 + size
        }
        return nil
    }

    /// PICTURE 负载：type(4) + mimeLen(4) + mime + descLen(4) + desc + w(4) + h(4) + depth(4) + colors(4) + dataLen(4) + data
    static func parseFlacPicture(_ d: Data) -> Data? {
        let b = [UInt8](d)
        var i = 4
        func u32() -> UInt32? {
            guard i + 4 <= b.count else { return nil }
            let v = Data(b).u32be(i)
            i += 4
            return v
        }
        guard let mimeLen = u32(), i + Int(mimeLen) <= b.count else { return nil }   // i=4 已跳过 type
        i += Int(mimeLen)
        guard let descLen = u32(), i + Int(descLen) <= b.count else { return nil }
        i += Int(descLen)
        guard let _ = u32(), let _ = u32(), let _ = u32(), let _ = u32() else { return nil }  // w/h/depth/colors
        guard let dataLen = u32(), dataLen > 0, i + Int(dataLen) <= b.count else { return nil }
        return Data(b[i..<(i + Int(dataLen))])
    }

    /// 歌曲所在文件夹的封面图片：常见命名（不区分大小写）
    private static let coverStems = ["cover", "front", "folder", "album", "artwork", "art"]
    private static let imageExts = ["jpg", "jpeg", "png", "webp"]

    private static func extractFromFolder(_ dir: URL) -> Data? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return nil }
        let exact = Set(names.map { $0.lowercased() })
        for stem in coverStems {
            for ext in imageExts {
                if exact.contains("\(stem).\(ext)") {
                    let f = dir.appendingPathComponent("\(stem).\(ext)")
                    if let d = try? Data(contentsOf: f), !d.isEmpty { return d }
                }
            }
        }
        return nil
    }

    /// DSF：ID3v2 标签在文件尾部，从尾部窗口内找 "ID3" 头
    private static func extractFromDSF(fh: FileHandle, url: URL) -> Data? {
        let fileSize = (try? fh.seekToEnd()) ?? 0
        guard fileSize > 10 else { return nil }
        let window = min(fileSize, 8 * 1024 * 1024)
        try? fh.seek(toOffset: fileSize - window)
        guard let tail = try? fh.read(upToCount: Int(window)) else { return nil }
        // 从后往前找 ID3v2 头（3/4 版），并校验声明长度与实际到文件尾的距离吻合
        var i = tail.count - 10
        while i >= 0 {
            if tail[i] == 0x49, tail[i + 1] == 0x44, tail[i + 2] == 0x33,   // "ID3"
               tail[i + 3] == 3 || tail[i + 3] == 4,
               tail[i + 6] & 0x80 == 0, tail[i + 7] & 0x80 == 0,
               tail[i + 8] & 0x80 == 0, tail[i + 9] & 0x80 == 0 {
                let declared = Int(tail[i + 6]) << 21 | Int(tail[i + 7]) << 14
                             | Int(tail[i + 8]) << 7 | Int(tail[i + 9])
                // 标签总长 = 10 字节头 + 声明负载；容忍尾部少量填充
                if declared + 10 >= tail.count - i - 64 && declared + 10 <= tail.count - i {
                    return parseID3APIC(Data(tail[i...]))
                }
            }
            i -= 1
        }
        return nil
    }

    /// DFF：遍历顶层 chunk 找 "ID3 " chunk（size 含 12 字节头，大端）
    private static func extractFromDFF(fh: FileHandle, url: URL) -> Data? {
        let fileSize = (try? fh.seekToEnd()) ?? 0
        guard fileSize > 16 + 12 else { return nil }
        var offset: UInt64 = 16   // 跳过 FRM8 头
        while offset + 12 <= fileSize {
            guard let hdr = try? fh.readAt(offset, count: 12), hdr.count == 12 else { return nil }
            let id = String(decoding: hdr[0..<4], as: UTF8.self)
            let size = Data(hdr).u64be(4)
            guard offset + 12 + size <= fileSize else { return nil }
            if id == "ID3 " {
                guard size > 10,
                      let body = try? fh.readAt(offset + 12, count: Int(size)),
                      body.count == size else { return nil }
                return parseID3APIC(Data(body))
            }
            offset += 12 + size + (size & 1)
        }
        return nil
    }

    /// 解析 ID3v2.3/v2.4 帧，取第一个 APIC 图片数据
    static func parseID3APIC(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return nil }
        let major = b[3]
        guard major == 3 || major == 4 else { return nil }
        var pos = 10
        while pos + 10 <= b.count {
            guard let frameID = String(bytes: b[pos..<pos + 4], encoding: .ascii),
                  frameID.count == 4, frameID != "\0\0\0\0" else { return nil }
            let raw = UInt32(b[pos + 4]) << 24 | UInt32(b[pos + 5]) << 16
                    | UInt32(b[pos + 6]) << 8 | UInt32(b[pos + 7])
            // v2.4 帧大小为 syncsafe，v2.3 为普通大端
            let size = major == 4 ? syncsafe(raw) : Int(raw)
            let bodyStart = pos + 10
            guard size > 0, bodyStart + size <= b.count else { return nil }
            if frameID == "APIC" {
                return parseAPICPayload(Array(b[bodyStart..<bodyStart + size]))
            }
            pos = bodyStart + size
        }
        return nil
    }

    private static func syncsafe(_ v: UInt32) -> Int {
        Int(v & 0x7F) | Int((v >> 8) & 0x7F) << 7 | Int((v >> 16) & 0x7F) << 14 | Int((v >> 24) & 0x7F) << 21
    }

    /// APIC 负载：编码(1) + MIME(\0 结尾 ASCII) + 图片类型(1) + 描述(编码相关结尾) + 图片数据
    private static func parseAPICPayload(_ p: [UInt8]) -> Data? {
        guard p.count > 4 else { return nil }
        let encoding = p[0]
        var i = 1
        // MIME：找 0x00
        while i < p.count, p[i] != 0 { i += 1 }
        guard i + 1 < p.count else { return nil }
        i += 1          // 跳过 MIME 的 \0
        i += 1          // 跳过图片类型字节
        // 描述：编码 1/2（UTF-16）以 00 00 结尾，其余以 00 结尾
        if encoding == 1 || encoding == 2 {
            while i + 1 < p.count, !(p[i] == 0 && p[i + 1] == 0) { i += 2 }
            i += 2
        } else {
            while i < p.count, p[i] != 0 { i += 1 }
            i += 1
        }
        guard i < p.count else { return nil }
        return Data(p[i...])
    }
}
