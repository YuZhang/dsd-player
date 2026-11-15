import Foundation

enum DSDError: Error, LocalizedError {
    case unsupportedFormat(String)
    case corruptFile(String)
    case unsupportedChannels(Int)
    case unsupportedSampleRate(UInt32)
    case dstCompressed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let s): return "Unsupported file format: \(s)"
        case .corruptFile(let s): return "File is corrupt or unparseable: \(s)"
        case .unsupportedChannels(let n): return "\(n) channels not supported (mono/stereo only)"
        case .unsupportedSampleRate(let r): return "Unsupported DSD sample rate: \(r) Hz"
        case .dstCompressed: return "DST-compressed DFF files are not supported"
        }
    }
}

struct DSDInfo: Hashable {
    let formatName: String              // "DSF" / "DFF"
    let dsdSampleRate: UInt32           // 2822400 / 5644800 / 11289600 ...
    let channelCount: Int
    let totalSamplesPerChannel: UInt64  // 单位: bit

    var durationSeconds: Double { Double(totalSamplesPerChannel) / Double(dsdSampleRate) }
    var dopCarrierRate: Double { Double(dsdSampleRate) / 16.0 }
    var dsdMultiple: Int { Int(dsdSampleRate / 44100) }
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
