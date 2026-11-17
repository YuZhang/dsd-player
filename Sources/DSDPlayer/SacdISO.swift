import Foundation
import Cdstdec

// MARK: - SACD ISO (ScarletBook) 解析
//
// 结构（偏移参照 sacd-ripper 的 scarletbook.h，全部大端）：
//   Master TOC @ LSN 510：2ch 区 TOC 位置在 0x40，多声道区在 0x48（0 = 无）
//   Area TOC @ 上述 LSN：声道数 0x20，曲目数 0x45，音频区起止 0x48/0x4C
//   曲目表 SACDTRL1 / 时间表 SACDTRL2 / 曲目文本 SACDTTxt 在 TOC 区内按签名扫描

struct SacdTrack {
    let index: Int          // 从 0 开始
    let startLSN: UInt64    // 曲目起始扇区（绝对 LSN）
    let lengthLSN: UInt64   // 曲目扇区数
    let title: String
    let performer: String
    let durationSeconds: Double
}

struct SacdAlbumInfo {
    let trackCount: Int
    let channelCount: Int
    let dstEncoded: Bool
    let audioStartLSN: UInt64
    let audioEndLSN: UInt64
    let tracks: [SacdTrack]
}

enum SacdISOError: Error, LocalizedError {
    case notSACD, noStereoArea, noTrackList

    var errorDescription: String? {
        switch self {
        case .notSACD: return "Not a SACD ISO (missing Master TOC)"
        case .noStereoArea: return "No stereo area found in this SACD ISO"
        case .noTrackList: return "Track list not found in this SACD ISO"
        }
    }
}

/// SACD ISO 解析器（只读，按需读取扇区）
final class SacdISO {
    private let file: FileHandle
    let album: SacdAlbumInfo
    /// 同一 ISO 的所有曲目共享一个 FileHandle，seek+read 非原子，必须串行化
    ///（无缝预排会在播放当前曲目的同时打开下一首，共享句柄并发读会读花数据）
    let readLock = NSLock()

    init(url: URL) throws {
        file = try FileHandle(forReadingFrom: url)

        // Master TOC
        let mtoc = try file.readAt(510 * 2048, count: 2048)
        guard mtoc.count == 2048,
              String(decoding: mtoc[0..<8], as: UTF8.self) == "SACDMTOC"
        else { throw SacdISOError.notSACD }

        let area1TOC1 = Data(mtoc).u32be(0x40)   // 2ch 区 TOC-1
        guard area1TOC1 > 0 else { throw SacdISOError.noStereoArea }

        // Area TOC
        let atocLSN = UInt64(area1TOC1)
        let atoc = try file.readAt(atocLSN * 2048, count: 2048)
        guard String(decoding: atoc[0..<8], as: UTF8.self) == "TWOCHTOC"
        else { throw SacdISOError.noStereoArea }

        let channelCount = Int(atoc[0x20])
        let trackCount = Int(atoc[0x45])
        let frameFormat = atoc[0x15] & 0x0F       // 0 = DST，2/3 = 未压缩 DSD
        let dstEncoded = frameFormat == 0
        let audioStart = UInt64(Data(atoc).u32be(0x48))
        let audioEnd = UInt64(Data(atoc).u32be(0x4C))

        // TOC 区内扫描各表（签名定位）
        let tocAreaSize = Int(Data(mtoc).u16be(0x54))   // 区 TOC 占的扇区数
        var tracklistData: [UInt8]?
        var trackTimeData: [UInt8]?
        var trackTextData: [UInt8]?
        for s in 0..<tocAreaSize {
            let sector = try file.readAt((atocLSN + UInt64(s)) * 2048, count: 2048)
            let sig = String(decoding: sector[0..<8], as: UTF8.self)
            switch sig {
            case "SACDTRL1": tracklistData = sector
            case "SACDTRL2": trackTimeData = sector
            case "SACDTTxt":
                // 文本区可能跨多个扇区（position 是相对整个文本区的偏移），读到 TOC 区末尾
                var text = sector
                let remaining = tocAreaSize - s - 1
                if remaining > 0 {
                    let more = try file.readAt((atocLSN + UInt64(s) + 1) * 2048, count: remaining * 2048)
                    text.append(contentsOf: more)
                }
                trackTextData = text
            default: break
            }
        }
        guard let trl1 = tracklistData else { throw SacdISOError.noTrackList }

        // 曲目文本（标题/艺术家）
        let textByTrack = SacdISO.parseTrackText(trackTextData, trackCount: trackCount)

        var tracks: [SacdTrack] = []
        for i in 0..<trackCount {
            let start = UInt64(Data(trl1).u32be(8 + i * 4))
            let length = UInt64(Data(trl1).u32be(8 + 255 * 4 + i * 4))
            var duration = 0.0
            if let trl2 = trackTimeData {
                // duration[i]: 分/秒/帧（75 帧/秒）
                let off = 8 + 255 * 4 + i * 4
                let minutes = Int(trl2[off]), seconds = Int(trl2[off + 1]), frames = Int(trl2[off + 2])
                duration = Double(minutes * 60 * 75 + seconds * 75 + frames) / 75.0
            }
            let text = textByTrack[i] ?? (title: "", performer: "")
            tracks.append(SacdTrack(index: i, startLSN: start, lengthLSN: length,
                                    title: text.title, performer: text.performer,
                                    durationSeconds: duration))
        }

        album = SacdAlbumInfo(trackCount: trackCount, channelCount: channelCount,
                              dstEncoded: dstEncoded,
                              audioStartLSN: audioStart, audioEndLSN: audioEnd,
                              tracks: tracks)
    }

    func makeTrackSource(_ track: SacdTrack) throws -> SacdTrackSource {
        try SacdTrackSource(file: file, readLock: readLock, track: track,
                            channelCount: album.channelCount, dstEncoded: album.dstEncoded)
    }

    /// 解析 SACDTTxt：每首曲目一个文本块，含标题(0x01)/艺术家(0x02)等类型条目
    private static func parseTrackText(_ data: [UInt8]?, trackCount: Int)
        -> [Int: (title: String, performer: String)] {
        guard let data, data.count >= 8 + trackCount * 2 else { return [:] }
        var result: [Int: (title: String, performer: String)] = [:]
        for i in 0..<trackCount {
            let pos = Int(Data(data).u16be(8 + i * 2))
            guard pos > 0, pos + 4 < data.count else { continue }
            let amount = Int(data[pos])
            var p = pos + 4
            var title = "", performer = ""
            for _ in 0..<amount {
                guard p + 2 < data.count else { break }
                let type = data[p]
                p += 2   // 跳过类型字节 + 0x20
                // 以 0 结尾的字符串
                var end = p
                while end < data.count && data[end] != 0 { end += 1 }
                let raw = Array(data[p..<end])
                let text = String(decoding: raw, as: UTF8.self)
                if type == 0x01 { title = text }
                else if type == 0x02 { performer = text }
                p = end + 1
            }
            result[i] = (title, performer)
        }
        return result
    }
}

// MARK: - SACD 曲目数据源（帧装配 + DST 解码）

/// 把一个 SACD 曲目暴露为 DSDSource：读任意偏移的声道交错 DSD 字节
final class SacdTrackSource: DSDSource {
    let info: DSDInfo
    let totalBytesPerChannel: UInt64

    private let file: FileHandle
    private let readLock: NSLock   // 与同一 ISO 的其他曲目共享的读锁
    private let track: SacdTrack
    private let channels: Int
    private let dstEncoded: Bool

    /// 每帧每声道字节数（SACD 恒定 4704 = 588 × 64 / 8）
    private let bytesPerFramePerChannel = 4704

    /// 帧索引：每帧的起始扇区（打开时扫描曲目区建立，支持随机 seek）
    private var frameStartLSNs: [UInt64] = []

    /// 当前解码帧缓存（帧号 + 交错字节）
    private var cachedFrameIndex = -1
    private var cachedFrameData: [UInt8] = []

    /// 帧索引后台构建（打开曲目不再阻塞主线程）；就绪信号
    private let indexReady = DispatchSemaphore(value: 0)
    private var indexBuilding = false

    /// DST 解码器实例与输出缓冲（解码是异步管线，回调完成后用信号量同步）
    private var decoder: OpaquePointer?   // dst_decoder_t*
    private var decodedOutput = [UInt8]()
    private let decodeSemaphore = DispatchSemaphore(value: 0)
    private var decodeError: String?

    init(file: FileHandle, readLock: NSLock, track: SacdTrack, channelCount: Int, dstEncoded: Bool) throws {
        self.file = file
        self.readLock = readLock
        self.track = track
        self.channels = channelCount
        self.dstEncoded = dstEncoded

        let totalFrames = track.durationSeconds > 0
            ? UInt64(track.durationSeconds * 75)
            : UInt64(track.lengthLSN) * 2048 / 4704
        totalBytesPerChannel = totalFrames * 4704
        info = DSDInfo(formatName: "SACD", dsdSampleRate: 2_822_400,
                       channelCount: channelCount,
                       totalSamplesPerChannel: totalBytesPerChannel * 8)

        // 帧索引后台构建，不阻塞 UI（点击歌曲立即响应）
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            try? buildFrameIndex()
            indexReady.signal()
        }
    }

    deinit {
        if let decoder { dst_decoder_destroy(decoder) }
    }

    /// 加锁读扇区：FileHandle 的 seek+read 非原子，多曲目共享句柄时必须串行
    private func readSector(_ lsn: UInt64) throws -> [UInt8] {
        readLock.lock()
        defer { readLock.unlock() }
        return try file.readAt(lsn * 2048, count: 2048)
    }

    /// 扫描曲目所有扇区，记录每帧的起始扇区（仅解析包头，不读音频负载，速度快）
    private func buildFrameIndex() throws {
        var index: [UInt64] = []
        let endLSN = track.startLSN + track.lengthLSN
        var lsn = track.startLSN
        while lsn < endLSN {
            let sector = try readSector(lsn)
            guard sector.count == 2048 else { break }
            let packetInfoCount = Int((sector[0] >> 5) & 7)
            for i in 0..<packetInfoCount {
                let b0 = sector[1 + i * 2]
                let frameStart = (b0 >> 7) & 1 == 1
                let dataType = (b0 >> 3) & 7
                if dataType == 2 && frameStart {
                    index.append(lsn)   // 该帧起始于本扇区
                }
            }
            lsn += 1
        }
        frameStartLSNs = index
    }

    /// 解码指定帧，结果缓存。返回声道交错字节（channels × 4704）
    private func decodeFrame(at frameIndex: Int) throws -> [UInt8] {
        if frameIndex == cachedFrameIndex { return cachedFrameData }

        // 帧索引尚未就绪（后台构建中）：播放线程等待，UI 不受影响
        if frameStartLSNs.isEmpty {
            _ = indexReady.wait(timeout: .now() + 10)
        }
        guard frameIndex >= 0, frameIndex < frameStartLSNs.count else { return [] }
        var lsn = frameStartLSNs[frameIndex]
        let endLSN = track.startLSN + track.lengthLSN

        var frameData = [UInt8]()
        var sectorCount = -1
        var started = false
        var done = false

        while lsn < endLSN && !done {
            let sector = try readSector(lsn)
            guard sector.count == 2048 else { break }
            let packetInfoCount = Int((sector[0] >> 5) & 7)
            let frameInfoCount = Int((sector[0] >> 2) & 7)
            let dstFlag = sector[0] & 1 == 1
            let frameInfoSize = dstFlag ? 4 : 3
            var pktOffset = 1 + packetInfoCount * 2 + frameInfoCount * frameInfoSize
            var frameInfoIdx = 0   // 当前扇区内的帧序号

            for i in 0..<packetInfoCount {
                let b0 = sector[1 + i * 2], b1 = sector[1 + i * 2 + 1]
                let frameStart = (b0 >> 7) & 1 == 1
                let dataType = (b0 >> 3) & 7
                let packetLength = Int(b0 & 7) << 8 | Int(b1)
                defer { pktOffset += packetLength }
                guard dataType == 2 else { continue }   // 只要 AUDIO 包

                if frameStart {
                    if started {
                        // 上一帧已完整（DST 以 sector_count 归零判断）
                        if !dstEncoded || sectorCount == 0 {
                            done = true
                            break
                        }
                    }
                    // 新帧：sector_count 在该帧 frame_info 的第 4 字节（bits 2-6）
                    if dstFlag {
                        let fiOff = 1 + packetInfoCount * 2 + frameInfoIdx * frameInfoSize + 3
                        sectorCount = Int((sector[fiOff] >> 2) & 0x1F)
                    }
                    frameInfoIdx += 1
                    started = true
                    frameData.removeAll(keepingCapacity: true)
                }
                if started {
                    frameData.append(contentsOf: sector[pktOffset..<(pktOffset + packetLength)])
                    if dstFlag { sectorCount -= 1 }
                    // 防御：DST 解码器输入缓冲池只有 64KB，帧异常时截断而不是堆溢出
                    if frameData.count > 64 * 1024 {
                        print("SACD frame overflow at track \(track.index), frame \(frameIndex), size \(frameData.count)")
                        done = true
                        break
                    }
                }
            }
            lsn += 1
        }

        var output = [UInt8]()
        if dstEncoded {
            if decoder == nil {
                decoder = dst_decoder_create(Int32(channels), { data, size, userdata in
                    guard let userdata else { return }
                    let src = Unmanaged<SacdTrackSource>.fromOpaque(userdata).takeUnretainedValue()
                    if let data, size > 0 {
                        src.decodedOutput = Array(UnsafeBufferPointer(start: data, count: size))
                    }
                    src.decodeSemaphore.signal()
                }, { count, code, message, userdata in
                    // 解码错误回调
                    if let userdata {
                        let src = Unmanaged<SacdTrackSource>.fromOpaque(userdata).takeUnretainedValue()
                        src.decodeError = message.map { String(cString: $0) }
                        src.decodeSemaphore.signal()
                    }
                }, Unmanaged.passUnretained(self).toOpaque())
            }
            decodedOutput = []
            decodeError = nil
            frameData.withUnsafeMutableBytes { ptr in
                if let base = ptr.baseAddress {
                    dst_decoder_decode(decoder, base.assumingMemoryBound(to: UInt8.self), ptr.count)
                }
            }
            // 等待异步解码完成（2 秒超时兜底）
            _ = decodeSemaphore.wait(timeout: .now() + 2)
            if let e = decodeError { print("DST decode error: \(e)") }
            output = decodedOutput
        } else {
            output = frameData
        }

        cachedFrameIndex = frameIndex
        cachedFrameData = output
        return output
    }

    // MARK: DSDSource

    func read(channelByteOffset off: UInt64, perChannelByteCount n: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(n * channels)
        var remaining = n
        var pos = off
        while remaining > 0 && pos < totalBytesPerChannel {
            let frameIndex = Int(pos / UInt64(bytesPerFramePerChannel))
            let inFrame = Int(pos % UInt64(bytesPerFramePerChannel))
            let take = min(remaining, bytesPerFramePerChannel - inFrame)
            let data = try decodeFrame(at: frameIndex)
            if data.isEmpty {
                // 解码失败/越界：填 DSD 静音保持输出
                out.append(contentsOf: [UInt8](repeating: 0x69, count: take * channels))
            } else {
                for i in 0..<take {
                    for c in 0..<channels {
                        let idx = (inFrame + i) * channels + c
                        out.append(idx < data.count ? data[idx] : 0x69)
                    }
                }
            }
            pos += UInt64(take)
            remaining -= take
        }
        return out
    }
}
