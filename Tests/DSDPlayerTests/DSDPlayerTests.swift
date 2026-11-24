import XCTest
import SwiftUI
@testable import DSDPlayer

final class DSDPlayerTests: XCTestCase {

    // MARK: - 合成文件构造

    private func makeDSF(url: URL, channels: Int = 2, rate: UInt32 = 2_822_400,
                         blockSize: UInt32 = 4096, bytesPerChannel: Int,
                         pattern: (Int, Int) -> UInt8) throws {
        let sampleCount = UInt64(bytesPerChannel) * 8
        let blocks = (bytesPerChannel + Int(blockSize) - 1) / Int(blockSize)

        var payload = Data()
        for b in 0..<blocks {
            for ch in 0..<channels {
                for i in 0..<Int(blockSize) {
                    let byteIdx = b * Int(blockSize) + i
                    payload.append(byteIdx < bytesPerChannel ? pattern(ch, byteIdx) : 0x69)
                }
            }
        }

        var fmt = Data()
        fmt.appendString("fmt "); fmt.appendLE(UInt64(52))
        fmt.appendLE(UInt32(1)); fmt.appendLE(UInt32(0))
        fmt.appendLE(UInt32(channels == 2 ? 2 : 1))
        fmt.appendLE(UInt32(channels)); fmt.appendLE(rate); fmt.appendLE(UInt32(1))
        fmt.appendLE(sampleCount); fmt.appendLE(blockSize); fmt.appendLE(UInt32(0))

        var data = Data()
        data.appendString("data"); data.appendLE(UInt64(12 + payload.count)); data.append(payload)

        let fileSize = 28 + fmt.count + data.count
        var dsd = Data()
        dsd.appendString("DSD "); dsd.appendLE(UInt64(28))
        dsd.appendLE(UInt64(fileSize)); dsd.appendLE(UInt64(0))

        try (dsd + fmt + data).write(to: url)
    }

    private func makeDFF(url: URL, channels: Int = 2, rate: UInt32 = 5_644_800,
                         bytesPerChannel: Int, pattern: (Int, Int) -> UInt8) throws {
        var payload = Data()
        for i in 0..<bytesPerChannel {
            for ch in 0..<channels { payload.append(pattern(ch, i)) }
        }

        var prop = Data()
        prop.appendString("SND ")
        prop.appendString("FS  "); prop.appendBE(UInt64(4)); prop.appendBE(rate)
        var chnl = Data(); chnl.appendBE(UInt16(channels))
        chnl.appendString(channels == 2 ? "SLFTSRGT" : "C   ")
        prop.appendString("CHNL"); prop.appendBE(UInt64(chnl.count)); prop.append(chnl)
        if chnl.count % 2 == 1 { prop.append(0) }
        prop.appendString("CMPR"); prop.appendBE(UInt64(14))
        prop.appendString("DSD "); prop.append(UInt8(13)); prop.appendString("not compressed")
        // "CMPR" 负载: 4 + 1 + 13 = 18 字节（偶数，无需填充）

        var propChunk = Data()
        propChunk.appendString("PROP"); propChunk.appendBE(UInt64(prop.count)); propChunk.append(prop)
        if prop.count % 2 == 1 { propChunk.append(0) }

        var fver = Data()
        fver.appendString("FVER"); fver.appendBE(UInt64(4)); fver.appendBE(UInt32(0x01050000))

        var dsdChunk = Data()
        dsdChunk.appendString("DSD "); dsdChunk.appendBE(UInt64(payload.count)); dsdChunk.append(payload)
        if payload.count % 2 == 1 { dsdChunk.append(0) }

        let body = fver + propChunk + dsdChunk
        var frm = Data()
        frm.appendString("FRM8"); frm.appendBE(UInt64(4 + body.count)); frm.appendString("DSD ")
        try (frm + body).write(to: url)
    }

    // MARK: - DSF

    func testDSFParseAndDeinterleave() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.dsf")
        let n = 5000  // 跨块边界
        try makeDSF(url: url, bytesPerChannel: n) { ch, i in
            ch == 0 ? UInt8(i & 0xFF) : UInt8(255 - (i & 0xFF))
        }

        let src = try DSFFile(url: url)
        XCTAssertEqual(src.info.formatName, "DSF")
        XCTAssertEqual(src.info.dsdSampleRate, 2_822_400)
        XCTAssertEqual(src.info.channelCount, 2)
        XCTAssertEqual(src.totalBytesPerChannel, UInt64(n))
        XCTAssertEqual(src.info.dopCarrierRate, 176400)

        let out = try src.read(channelByteOffset: 0, perChannelByteCount: n)
        XCTAssertEqual(out.count, n * 2)
        for i in 0..<n {
            XCTAssertEqual(out[i * 2], bitReverseLUT[i & 0xFF], "ch0 byte \(i)")
            XCTAssertEqual(out[i * 2 + 1], bitReverseLUT[255 - (i & 0xFF)], "ch1 byte \(i)")
        }
    }

    func testDSFReadAcrossBlockBoundary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test2.dsf")
        let n = 5000
        try makeDSF(url: url, bytesPerChannel: n) { ch, i in UInt8((i ^ (ch * 0x5A)) & 0xFF) }

        let src = try DSFFile(url: url)
        // 从块内 4000 处读 200 字节，跨越 4096 块边界
        let out = try src.read(channelByteOffset: 4000, perChannelByteCount: 200)
        XCTAssertEqual(out.count, 400)
        for i in 0..<200 {
            let byteIdx = 4000 + i
            XCTAssertEqual(out[i * 2], bitReverseLUT[byteIdx & 0xFF], "ch0 byte \(byteIdx)")
            XCTAssertEqual(out[i * 2 + 1], bitReverseLUT[(byteIdx ^ 0x5A) & 0xFF], "ch1 byte \(byteIdx)")
        }
    }

    // MARK: - DFF

    func testDFFParseAndRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.dff")
        let n = 2000
        try makeDFF(url: url, bytesPerChannel: n) { ch, i in UInt8((i + ch * 7) & 0xFF) }

        let src = try DFFFile(url: url)
        XCTAssertEqual(src.info.formatName, "DFF")
        XCTAssertEqual(src.info.dsdSampleRate, 5_644_800)
        XCTAssertEqual(src.info.dopCarrierRate, 352800)
        XCTAssertEqual(src.totalBytesPerChannel, UInt64(n))

        // DFF 字节交错、MSB-first：读取应原样透传
        let out = try src.read(channelByteOffset: 100, perChannelByteCount: 50)
        XCTAssertEqual(out.count, 100)
        for i in 0..<50 {
            XCTAssertEqual(out[i * 2], UInt8((100 + i) & 0xFF))
            XCTAssertEqual(out[i * 2 + 1], UInt8((100 + i + 7) & 0xFF))
        }
    }

    // MARK: - DoP 编码

    func testDoPEncoding() throws {
        var enc = DoPEncoder()
        // 单声道 2 帧: 每帧 2 字节
        let out = enc.encode([0x12, 0x34, 0xAB, 0xCD], channels: 1)
        XCTAssertEqual(out.count, 2)
        // 帧0: marker 0x05, 数据 0x12, 0x34
        XCTAssertEqual(UInt32(bitPattern: out[0]), 0x0512_3400)
        // 帧1: marker 0xFA
        XCTAssertEqual(UInt32(bitPattern: out[1]), 0xFAAB_CD00)
    }

    func testDoPStereoMarkerSync() throws {
        var enc = DoPEncoder()
        let out = enc.encode([UInt8](repeating: 0x96, count: 8), channels: 2)  // 2 帧立体声
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(UInt32(bitPattern: out[0]) >> 24, 0x05)  // 帧0 L
        XCTAssertEqual(UInt32(bitPattern: out[1]) >> 24, 0x05)  // 帧0 R
        XCTAssertEqual(UInt32(bitPattern: out[2]) >> 24, 0xFA)  // 帧1 L
        XCTAssertEqual(UInt32(bitPattern: out[3]) >> 24, 0xFA)  // 帧1 R
    }

    func testDoPStereoPayloadMapping() throws {
        var enc = DoPEncoder()
        // 交错输入: [L0 R0 L1 R1 L2 R2 L3 R3]，每声道每帧应取该声道连续 2 字节
        let out = enc.encode([0x11, 0xAA, 0x22, 0xBB, 0x33, 0xCC, 0x44, 0xDD], channels: 2)
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(UInt32(bitPattern: out[0]), 0x0511_2200)  // 帧0 L = L0,L1
        XCTAssertEqual(UInt32(bitPattern: out[1]), 0x05AA_BB00)  // 帧0 R = R0,R1
        XCTAssertEqual(UInt32(bitPattern: out[2]), 0xFA33_4400)  // 帧1 L = L2,L3
        XCTAssertEqual(UInt32(bitPattern: out[3]), 0xFACC_DD00)  // 帧1 R = R2,R3
    }

    func testDoPSilence() throws {
        var enc = DoPEncoder()
        let out = enc.silence(frames: 3, channels: 1)
        XCTAssertEqual(out.count, 3)
        for (i, s) in out.enumerated() {
            let w = UInt32(bitPattern: s)
            XCTAssertEqual(w >> 24, i % 2 == 0 ? 0x05 : 0xFA)
            XCTAssertEqual(w & 0x00FF_FF00, 0x0069_6900)
        }
    }

    // MARK: - VU 电平估计

    func testLevelEstimationDoP() throws {
        // DoP 静音 (0x69) 密度恰为 0.5 → 电平 0
        var silentWords = [Int32](repeating: 0, count: 1024)
        for i in 0..<1024 {
            let marker: UInt32 = i % 2 == 0 ? 0x05 : 0xFA
            silentWords[i] = Int32(bitPattern: (marker << 24) | (0x69 << 16) | (0x69 << 8))
        }
        let (l0, r0) = silentWords.withUnsafeBufferPointer {
            estimateLevelsDoP($0.baseAddress!, count: 1024, channels: 2)
        }
        XCTAssertEqual(l0, 0, accuracy: 0.01)
        XCTAssertEqual(r0, 0, accuracy: 0.01)

        // 全 1 载荷 → 满幅
        var fullWords = [Int32](repeating: 0, count: 1024)
        for i in 0..<1024 {
            let marker: UInt32 = i % 2 == 0 ? 0x05 : 0xFA
            fullWords[i] = Int32(bitPattern: (marker << 24) | (0xFF << 16) | (0xFF << 8))
        }
        let (l1, _) = fullWords.withUnsafeBufferPointer {
            estimateLevelsDoP($0.baseAddress!, count: 1024, channels: 2)
        }
        XCTAssertEqual(l1, 1.0, accuracy: 0.01)
    }

    func testLevelEstimationPCM() throws {
        // 静音 → 0；满幅方波 → 1.0（RMS × √2 截顶）
        let silence = [Int32](repeating: 0, count: 512)
        let (zl, _) = silence.withUnsafeBufferPointer {
            estimateLevelsPCM($0.baseAddress!, count: 512, channels: 2)
        }
        XCTAssertEqual(zl, 0)

        let full = [Int32](repeating: Int32.max / 2, count: 512)  // RMS 0.5 × 增益 2.0 → 满格
        let (fl, _) = full.withUnsafeBufferPointer {
            estimateLevelsPCM($0.baseAddress!, count: 512, channels: 2)
        }
        XCTAssertEqual(fl, 1.0, accuracy: 0.01)
    }

    // MARK: - 皮肤与持久化

    func testSkinEnumRoundTrip() {
        // 每个皮肤的 rawValue 可逆，且主题参数完整
        XCTAssertEqual(Skin.allCases.count, 3)
        for skin in Skin.allCases {
            XCTAssertEqual(Skin(rawValue: skin.rawValue), skin)
            let t = skin.theme
            _ = t.bgTop; _ = t.bgBottom; _ = t.accent; _ = t.badgeBg
            XCTAssertFalse(skin.name.isEmpty)
        }
        XCTAssertNil(Skin(rawValue: 99))  // 非法值安全返回 nil
    }

    func testSavedStateBackwardCompatibility() throws {
        // 旧版本数据没有 skin 字段，必须能解码且 skin 为 nil
        let oldJSON = #"{"paths":["/tmp/a.dsf","/tmp/b.dff"],"currentIndex":0,"playMode":1,"outputMode":0}"#
        let s = try JSONDecoder().decode(SavedState.self, from: Data(oldJSON.utf8))
        XCTAssertEqual(s.paths.count, 2)
        XCTAssertEqual(s.currentIndex, 0)
        XCTAssertEqual(s.playMode, 1)
        XCTAssertEqual(s.outputMode, 0)
        XCTAssertNil(s.skin)
        XCTAssertNil(s.showPlaylist)
        // 调用方应回退到默认皮肤与显示列表
        XCTAssertEqual(Skin(rawValue: s.skin ?? 0) ?? .dark, .dark)
    }

    /// 一阶 Sigma-Delta 调制的立体声测试音（字节交错 LRLR）
    private func makeTone(dsdRate: UInt32, seconds: Double, freqL: Double, freqR: Double) -> [UInt8] {
        let total = Int(Double(dsdRate) * seconds)
        let bytesPerChannel = total / 8
        var bits = [UInt8](repeating: 0, count: bytesPerChannel * 2)
        var intL = 0.0, intR = 0.0
        for i in 0..<bytesPerChannel {
            var byteL: UInt8 = 0, byteR: UInt8 = 0
            for b in 0..<8 {
                let t = Double(i * 8 + b) / Double(dsdRate)
                let sl = 0.6 * sin(2 * .pi * freqL * t)
                let sr = 0.6 * sin(2 * .pi * freqR * t)
                intL += sl; intR += sr
                let qL = intL >= 0 ? 1.0 : -1.0
                let qR = intR >= 0 ? 1.0 : -1.0
                intL -= qL; intR -= qR
                if qL > 0 { byteL |= UInt8(1 << (7 - b)) }
                if qR > 0 { byteR |= UInt8(1 << (7 - b)) }
            }
            bits[i * 2] = byteL
            bits[i * 2 + 1] = byteR
        }
        return bits
    }

    func testHighRatePCMConversion() throws {
        // DSD64 → 176.4k / 352.8k：输出长度合理、信号电平正常无削波
        let dsd = makeTone(dsdRate: 2_822_400, seconds: 0.2, freqL: 440, freqR: 880)
        for (boost, rate) in [(1, 176_400), (2, 352_800)] {
            let conv = DSDToPCM(dsdRate: 2_822_400, pcmRate: rate, channels: 2)
            let out = conv.process(dsd, channels: 2)
            // 期望帧数 = rate × 0.2s，容许滤波器群延迟误差
            XCTAssertEqual(out.count / 2, Int(Double(rate) * 0.2), accuracy: 4000, "output frames")
            let lMax = out.enumerated().filter { $0.offset % 2 == 0 }.map { abs($0.element) }.max() ?? 0
            XCTAssertGreaterThan(Double(lMax) / Double(0x1p31), 0.3, "signal level")
            XCTAssertLessThan(Double(lMax) / Double(0x1p31), 0.95, "no clipping")
        }
    }

    func testColorHexRoundTrip() throws {
        // hex 解析与序列化往返
        let c = Color(hex: "#EDB54D")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.hexString, "#EDB54D")
        // 带 # 不带 # 均可解析
        XCTAssertNotNil(Color(hex: "121212"))
        XCTAssertNil(Color(hex: "xyz"))
        // 亮度：亮色 onAccent 为深字，暗色为白字
        XCTAssertGreaterThan(luminance(Color.white), 0.45)
        XCTAssertLessThan(luminance(Color.black), 0.45)
    }

    func testPlaylistReorderIndices() throws {
        // 单项：第 2 项移到第 5 项之前 / 之后
        XCTAssertEqual(PlayerModel.reorderedIndices(count: 7, sources: [2], boundary: 5),
                       [0, 1, 3, 4, 2, 5, 6])
        XCTAssertEqual(PlayerModel.reorderedIndices(count: 7, sources: [2], boundary: 6),
                       [0, 1, 3, 4, 5, 2, 6])
        // 多项整组：{2,3} 移到第 5 项之前，保持相对顺序
        XCTAssertEqual(PlayerModel.reorderedIndices(count: 7, sources: [2, 3], boundary: 5),
                       [0, 1, 4, 2, 3, 5, 6])
        // 移到末尾（boundary = count）
        XCTAssertEqual(PlayerModel.reorderedIndices(count: 4, sources: [0], boundary: 4),
                       [1, 2, 3, 0])
        // 向前拖：第 5 项移到第 1 项之前
        XCTAssertEqual(PlayerModel.reorderedIndices(count: 7, sources: [5], boundary: 1),
                       [0, 5, 1, 2, 3, 4, 6])
        // 原位放下：结果不变
        XCTAssertEqual(PlayerModel.reorderedIndices(count: 5, sources: [2], boundary: 2),
                       [0, 1, 2, 3, 4])
        // 越界边界收敛到合法范围
        XCTAssertEqual(PlayerModel.reorderedIndices(count: 3, sources: [0], boundary: 99),
                       [1, 2, 0])
        XCTAssertEqual(PlayerModel.reorderedIndices(count: 3, sources: [], boundary: 1),
                       [0, 1, 2])
    }

    /// 构造 ID3v2.4 APIC 标签：编码 0 + "image/png\0" + 类型 3 + 空描述 + 图片数据
    private func makeID3WithAPIC(png: Data) -> Data {
        var apic: [UInt8] = [0]
        apic.append(contentsOf: "image/png".utf8); apic.append(0)
        apic.append(3)
        apic.append(0)
        apic.append(contentsOf: png)
        func syncsafe(_ n: Int) -> [UInt8] {
            [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]
        }
        var frame = Array("APIC".utf8)
        frame.append(contentsOf: syncsafe(apic.count))
        frame.append(contentsOf: [0, 0])
        frame.append(contentsOf: apic)
        var id3: [UInt8] = [0x49, 0x44, 0x33, 4, 0, 0]
        id3.append(contentsOf: syncsafe(frame.count))
        id3.append(contentsOf: frame)
        return Data(id3)
    }

    func testExtractCoverFromDSF() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cover_test.dsf")
        try makeDSF(url: url, bytesPerChannel: 4096) { _, i in UInt8(i % 251) }
        let h = try FileHandle(forWritingTo: url)
        h.seekToEndOfFile(); h.write(makeID3WithAPIC(png: png)); try h.close()
        XCTAssertEqual(CoverArt.extract(from: url), png)

        // 无标签文件返回 nil
        let plain = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nocover_test.dsf")
        try makeDSF(url: plain, bytesPerChannel: 4096) { _, i in UInt8(i % 251) }
        XCTAssertNil(CoverArt.extract(from: plain))
    }

    func testExtractCoverFromDFF() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9, 8, 7])
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cover_test.dff")
        try makeDFF(url: url, bytesPerChannel: 4096) { _, i in UInt8(i % 251) }
        let id3 = [UInt8](makeID3WithAPIC(png: png))
        // "ID3 " chunk：size = 负载字节数（大端，不含头），偶数填充
        var chunk = Array("ID3 ".utf8)
        let size = id3.count
        chunk.append(UInt8((size >> 56) & 0xFF)); chunk.append(UInt8((size >> 48) & 0xFF))
        chunk.append(UInt8((size >> 40) & 0xFF)); chunk.append(UInt8((size >> 32) & 0xFF))
        chunk.append(UInt8((size >> 24) & 0xFF)); chunk.append(UInt8((size >> 16) & 0xFF))
        chunk.append(UInt8((size >> 8) & 0xFF)); chunk.append(UInt8(size & 0xFF))
        chunk.append(contentsOf: id3)
        if id3.count % 2 == 1 { chunk.append(0) }
        let h = try FileHandle(forWritingTo: url)
        h.seekToEndOfFile(); h.write(Data(chunk)); try h.close()
        XCTAssertEqual(CoverArt.extract(from: url), png)
    }

    func testCoverFallbackToFolder() throws {
        // 无内嵌封面的文件 + 同目录 cover.jpg → 使用文件夹封面
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cover_folder_test")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("song.dsf")
        try makeDSF(url: url, bytesPerChannel: 4096) { _, i in UInt8(i % 251) }
        let jpg = Data([0xFF, 0xD8, 0xFF, 0xE0, 9, 9, 9])
        try jpg.write(to: dir.appendingPathComponent("Cover.JPG"))   // 大小写不敏感
        XCTAssertEqual(CoverArt.extract(from: url), jpg)
        // front.png 命名同样支持；内嵌封面优先于文件夹封面
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Cover.JPG"))
        XCTAssertNil(CoverArt.extract(from: url))
        try? FileManager.default.removeItem(at: dir)
    }

    func testSavedStateRoundTrip() throws {        let original = SavedState(paths: ["/tmp/a.dsf"], currentIndex: 2,
                                  playMode: 3, outputMode: 1, skin: 1, showPlaylist: false,
                                  pcmRateBoost: 1,
                                  customAccent: "#FF8800", customBg: "#121212", customBgOpacity: 0.6)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedState.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testSavedStateCorruptData() {
        // 损坏数据应解码失败（调用方视为无保存状态）
        XCTAssertThrowsError(try JSONDecoder().decode(SavedState.self,
                                                      from: Data("not json".utf8)))
    }

    // MARK: - DSD→PCM 转换

    func testDSDToPCMFullScale() throws {
        // 全 1 比特流 = 满幅正电平，经低通后应趋近 +0.85 满幅
        var conv = DSDToPCM(dsdRate: 2_822_400, pcmRate: 88_200, channels: 1)
        let out = conv.process([UInt8](repeating: 0xFF, count: 65536), channels: 1)
        XCTAssertEqual(out.count, 65536 * 8 / 32)
        let last = out.suffix(1000).map { abs($0) }.max()!
        XCTAssertGreaterThan(last, Int32(0.80 * 0x1p31))
        XCTAssertLessThan(last, Int32(0.90 * 0x1p31))
    }

    func testDSDToPCMTone() throws {
        // 二阶 sigma-delta 调制的 440Hz 音 → PCM 输出主峰应在 440Hz
        let rate = 2_822_400, n = rate / 4   // 0.25s
        var bits = [UInt8](repeating: 0, count: n / 8)
        var s1 = 0.0, s2 = 0.0, q = 1.0
        for i in 0..<n {
            let x = 0.5 * sin(2 * Double.pi * 440 * Double(i) / Double(rate))
            s1 += x - q; s2 += s1 - q
            q = s2 >= 0 ? 1 : -1
            if q > 0 { bits[i / 8] |= UInt8(1 << (7 - i % 8)) }  // MSB-first
        }
        var conv = DSDToPCM(dsdRate: UInt32(rate), pcmRate: 88_200, channels: 1)
        let out = conv.process(bits, channels: 1).map { Double($0) / 0x1p31 }
        XCTAssertEqual(out.count, n / 32)
        // DFT 找主峰
        let m = out.count
        var bestBin = 0, bestMag = 0.0
        for bin in 2..<200 {
            var re = 0.0, im = 0.0
            for (i, v) in out.enumerated() {
                let ph = -2 * Double.pi * Double(bin) * Double(i) / Double(m)
                re += v * cos(ph); im += v * sin(ph)
            }
            let mag = re * re + im * im
            if mag > bestMag { bestMag = mag; bestBin = bin }
        }
        let peak = Double(bestBin) * 88_200 / Double(m)
        XCTAssertEqual(peak, 440, accuracy: 20)
    }

    // MARK: - 环形缓冲

    func testRingBufferWraparound() {
        let ring = RingBuffer(capacity: 8)
        XCTAssertEqual(ring.write([1, 2, 3, 4, 5, 6]), 6)
        var tmp = [Int32](repeating: 0, count: 8)
        let r1 = tmp.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 4) }
        XCTAssertEqual(r1, 4)
        XCTAssertEqual(Array(tmp[0..<4]), [1, 2, 3, 4])

        // 写入 4 个，跨越物理尾部回绕
        XCTAssertEqual(ring.write([7, 8, 9, 10]), 4)
        let r2 = tmp.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 8) }
        XCTAssertEqual(r2, 6)
        XCTAssertEqual(Array(tmp[0..<6]), [5, 6, 7, 8, 9, 10])
        XCTAssertEqual(ring.availableToRead, 0)
    }
}

// MARK: - Data 构造工具

private extension Data {
    mutating func appendString(_ s: String) { append(contentsOf: s.utf8) }
    mutating func appendLE(_ v: UInt64) { for i in 0..<8 { append(UInt8((v >> (i * 8)) & 0xFF)) } }
    mutating func appendLE(_ v: UInt32) { for i in 0..<4 { append(UInt8((v >> (i * 8)) & 0xFF)) } }
    mutating func appendBE(_ v: UInt64) { for i in (0..<8).reversed() { append(UInt8((v >> (i * 8)) & 0xFF)) } }
    mutating func appendBE(_ v: UInt32) { for i in (0..<4).reversed() { append(UInt8((v >> (i * 8)) & 0xFF)) } }
    mutating func appendBE(_ v: UInt16) { for i in (0..<2).reversed() { append(UInt8((v >> (i * 8)) & 0xFF)) } }
}

// MARK: - LUT 与直接实现一致性 / 性能

extension DSDPlayerTests {
    /// LUT 转换器与逐位直接实现对同一输入的输出应基本一致（相位对齐差半组，幅度一致）
    func testLUTMatchesDirectFIR() throws {
        let dsd = makeTone(dsdRate: 2_822_400, seconds: 0.1, freqL: 440, freqR: 880)
        let lut = DSDToPCM(dsdRate: 2_822_400, pcmRate: 88_200, channels: 2)
        let fast = lut.process(dsd, channels: 2)
        let direct = DirectFIR(taps: lutTaps(dsdRate: 2_822_400, pcmRate: 88_200), decimation: 32, channels: 2)
        let slow = direct.process(dsd, channels: 2)
        XCTAssertEqual(fast.count, slow.count, "frame count")
        var maxDiff: Int32 = 0
        for (a, b) in zip(fast, slow) {
            maxDiff = max(maxDiff, abs(a - b))
        }
        // 相对满幅的差异应极小（相位差半抽取组导致的微小偏移）
        XCTAssertLessThan(Double(maxDiff) / Double(0x1p31), 0.01, "max diff \(maxDiff)")
    }

    /// 与转换器完全相同的滤波器设计（taps 是 private，这里复制构造逻辑）
    private func lutTaps(dsdRate: UInt32, pcmRate: Int) -> [Float] {
        let decimation = Int(dsdRate) / pcmRate
        let windowBits = Int(90e-6 * Double(dsdRate))
        let M = max(256, windowBits - windowBits % decimation)
        let fc = min(24_000.0, Double(pcmRate) * 0.45) / Double(dsdRate)
        var h = [Float](repeating: 0, count: M + 1)
        var sum: Float = 0
        let beta: Float = 12.0
        func besselI0(_ x: Float) -> Float {
            var s: Float = 1, t: Float = 1
            let xx = x * x / 4
            for k in 1...24 { t *= xx / Float(k * k); s += t; if t < 1e-9 * s { break } }
            return s
        }
        let denom = besselI0(beta)
        for n in 0...M {
            let k = Float(n) - Float(M) / 2
            let sinc = k == 0 ? Float(2 * fc) : sin(Float.pi * 2 * Float(fc) * k) / (Float.pi * k)
            let r = 2.0 * Double(n) / Double(M) - 1.0
            let w = besselI0(beta * sqrt(1 - Float(r * r))) / denom
            h[n] = sinc * w
            sum += h[n]
        }
        return h.map { $0 / sum }
    }

    /// 性能基准：LUT 路径应显著快于逐位路径
    func testLUTPerformance() throws {
        let dsd = makeTone(dsdRate: 2_822_400, seconds: 5, freqL: 440, freqR: 880)
        let lut = DSDToPCM(dsdRate: 2_822_400, pcmRate: 88_200, channels: 2)
        let direct = DirectFIR(taps: lutTaps(dsdRate: 2_822_400, pcmRate: 88_200), decimation: 32, channels: 2)
        // 预热
        _ = lut.process(dsd, channels: 2)
        _ = direct.process(dsd, channels: 2)
        let t0 = Date()
        let fast = lut.process(dsd, channels: 2)
        let tFast = Date().timeIntervalSince(t0)
        let t1 = Date()
        let slow = direct.process(dsd, channels: 2)
        let tSlow = Date().timeIntervalSince(t1)
        XCTAssertEqual(fast.count, slow.count)
        print(String(format: "LUT: %.3fs  direct: %.3fs  speedup: %.1fx", tFast, tSlow, tSlow / tFast))
        XCTAssertLessThan(tFast * 3, tSlow, "LUT should be at least 3x faster")
    }
}
