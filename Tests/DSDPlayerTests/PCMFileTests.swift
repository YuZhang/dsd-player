import XCTest
@testable import DSDPlayer

// MARK: - WAV / FLAC PCM 源测试

final class PCMFileTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcmtests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// 写一个最小 PCM WAV（16-bit 立体声，440Hz 正弦）
    private func makeWAV(name: String, rate: Int, bits: Int, channels: Int,
                         seconds: Double, freq: Double = 440) throws -> URL {
        let n = Int(Double(rate) * seconds)
        var data = [Int16]()
        data.reserveCapacity(n * channels)
        for i in 0..<n {
            let v = Int16(sin(2 * .pi * freq * Double(i) / Double(rate)) * 0.8 * 32767)
            for _ in 0..<channels { data.append(v) }
        }
        let byteRate = rate * channels * bits / 8
        let blockAlign = channels * bits / 8
        var bytes: [UInt8] = []
        func u32le(_ v: Int) { bytes += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        func u16le(_ v: Int) { bytes += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func ascii(_ s: String) { bytes += Array(s.utf8) }
        func pcm(_ d: [Int16]) { for v in d { bytes += [UInt8(UInt16(bitPattern: v) & 0xFF), UInt8((UInt16(bitPattern: v) >> 8) & 0xFF)] } }

        ascii("RIFF"); u32le(36 + n * blockAlign); ascii("WAVE")
        ascii("fmt "); u32le(16); u16le(1); u16le(channels); u32le(rate)
        u32le(byteRate); u16le(blockAlign); u16le(bits)
        ascii("data"); u32le(n * blockAlign); pcm(data)

        let url = tmpDir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: WAV

    func testWAVHeaderParse() throws {
        let url = try makeWAV(name: "a.wav", rate: 44100, bits: 16, channels: 2, seconds: 1)
        let m = try AVPCMFile.parseWAVHeader(url)
        XCTAssertEqual(m.rate, 44100)
        XCTAssertEqual(m.channels, 2)
        XCTAssertEqual(m.bits, 16)
    }

    func testWAV96k24bitMono() throws {
        // 手工构造 96k/24bit/单声道 头（不校验音频内容，只验解析）
        let rate = 96000, bits = 24, channels = 1
        var bytes: [UInt8] = []
        func u32le(_ v: Int) { bytes += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        func u16le(_ v: Int) { bytes += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func ascii(_ s: String) { bytes += Array(s.utf8) }
        let n = 96
        ascii("RIFF"); u32le(36 + n * 3); ascii("WAVE")
        ascii("fmt "); u32le(16); u16le(1); u16le(channels); u32le(rate)
        u32le(rate * 3); u16le(3); u16le(bits)
        ascii("data"); u32le(n * 3); bytes += [UInt8](repeating: 0, count: n * 3)
        let url = tmpDir.appendingPathComponent("b.wav")
        try Data(bytes).write(to: url)
        let m = try AVPCMFile.parseWAVHeader(url)
        XCTAssertEqual(m.rate, 96000)
        XCTAssertEqual(m.bits, 24)
        XCTAssertEqual(m.channels, 1)
    }

    func testWAVSourceInfoAndRead() throws {
        let url = try makeWAV(name: "c.wav", rate: 44100, bits: 16, channels: 2, seconds: 2)
        let src = try AVPCMFile(url: url)
        XCTAssertTrue(src.info.isPCM)
        XCTAssertEqual(src.info.formatName, "WAV")
        XCTAssertEqual(src.info.dsdSampleRate, 44100)
        XCTAssertEqual(src.info.channelCount, 2)
        XCTAssertEqual(src.info.bitDepth, 16)
        XCTAssertEqual(src.info.durationSeconds, 2, accuracy: 0.01)

        // 读 1 秒：帧数与采样值合理（16-bit 0.8 幅度 → 约 0.8 * Int32.max）
        let frames = try src.read(frameOffset: 0, frameCount: 44100)
        XCTAssertEqual(frames.count, 44100 * 2)
        let peak = frames.map { abs(Int64($0)) }.max()!
        XCTAssertGreaterThan(Double(peak), 0.7 * Double(Int32.max))
        XCTAssertLessThanOrEqual(Double(peak), 0.85 * Double(Int32.max))

        // 越界读：返回空
        XCTAssertTrue(try src.read(frameOffset: 999_000_000, frameCount: 100).isEmpty)

        // seek 读：第二秒开头应接近正弦过零
        let tail = try src.read(frameOffset: 44100, frameCount: 100)
        XCTAssertEqual(tail.count, 200)
        XCTAssertLessThan(abs(Int64(tail[0])), Int64(Double(Int32.max) * 0.1))
    }

    func testWAVNonPCMFails() throws {
        // "fmt" 为 0x55 (MP3) 应拒绝
        var bytes: [UInt8] = []
        func u32le(_ v: Int) { bytes += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        func u16le(_ v: Int) { bytes += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func ascii(_ s: String) { bytes += Array(s.utf8) }
        ascii("RIFF"); u32le(100); ascii("WAVE")
        ascii("fmt "); u32le(16); u16le(0x55); u16le(2); u32le(44100)
        u32le(176400); u16le(4); u16le(16)
        let url = tmpDir.appendingPathComponent("bad.wav")
        try Data(bytes).write(to: url)
        XCTAssertThrowsError(try AVPCMFile(url: url))
    }

    // MARK: FLAC

    /// 手工构造最小合法 FLAC：fLaC + STREAMINFO（无音频帧）
    private func makeFlacHeader(name: String, rate: Int, channels: Int, bits: Int) throws -> URL {
        var bytes: [UInt8] = Array("fLaC".utf8)
        var info = [UInt8](repeating: 0, count: 34)
        // 打包域（10..17）：rate 20bit | (ch-1) 3bit | (bits-1) 5bit | total 36bit
        var v = UInt64(rate) << 44
        v |= UInt64(channels - 1) << 41
        v |= UInt64(bits - 1) << 36
        v |= 1024   // total samples（假值，仅解析测试）
        for i in 0..<8 {
            info[10 + i] = UInt8((v >> UInt64(56 - 8 * i)) & 0xFF)
        }
        bytes.append(0x80)                 // last-block + type 0 (STREAMINFO)
        bytes.append(UInt8(info.count >> 16)); bytes.append(UInt8(info.count >> 8)); bytes.append(UInt8(info.count))
        bytes += info
        let url = tmpDir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func testFlacStreamInfoParse() throws {
        let url = try makeFlacHeader(name: "x.flac", rate: 96000, channels: 2, bits: 24)
        let m = try AVPCMFile.parseFlacStreamInfo(url)
        XCTAssertEqual(m.rate, 96000)
        XCTAssertEqual(m.channels, 2)
        XCTAssertEqual(m.bits, 24)
    }

    func testFlacStreamInfoDSD64Rate() throws {
        let url = try makeFlacHeader(name: "y.flac", rate: 44100, channels: 1, bits: 16)
        let m = try AVPCMFile.parseFlacStreamInfo(url)
        XCTAssertEqual(m.rate, 44100)
        XCTAssertEqual(m.channels, 1)
        XCTAssertEqual(m.bits, 16)
    }

    func testFlacNotAFlacFails() throws {
        let url = tmpDir.appendingPathComponent("z.flac")
        try Data("OggS....".utf8).write(to: url)
        XCTAssertThrowsError(try AVPCMFile.parseFlacStreamInfo(url))
    }

    // MARK: 统一打开

    func testUnifiedOpenDispatch() throws {
        let wav = try makeWAV(name: "u.wav", rate: 44100, bits: 16, channels: 2, seconds: 0.5)
        let src = try PCMFile.open(wav)
        XCTAssertTrue(src.info.isPCM)
        XCTAssertEqual(src.info.formatName, "WAV")
        XCTAssertFalse(PCMFile.isSupported(tmpDir.appendingPathComponent("a.dsf")))
        XCTAssertTrue(PCMFile.isSupported(wav))
    }

    // MARK: 引擎加载 PCM 源

    func testEngineLoadsPCMSource() throws {
        let url = try makeWAV(name: "eng.wav", rate: 44100, bits: 16, channels: 2, seconds: 1)
        let engine = PlaybackEngine()
        try engine.load(source: AudioSource.pcm(PCMFile.open(url)))
        XCTAssertEqual(engine.source?.info.isPCM, true)
        // PCM 源强制 PCM 通路：即使 outputMode=.dop，生效模式也是 PCM
        engine.outputMode = .dop
        engine.seek(toSeconds: 0.5)
        // 位置计算不崩即可（未播放时 positionSeconds=0）
        XCTAssertEqual(engine.positionSeconds, 0, accuracy: 0.001)
        engine.stop()
    }

    // MARK: FLAC 封面（PICTURE 块解析）

    func testFlacPictureParse() throws {
        // 构造 PICTURE 负载：type + mime("image/jpeg") + desc("") + w/h/depth/colors + PNG 数据
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xDE, 0xAD]
        var p: [UInt8] = []
        func u32be(_ v: Int) { p += [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        u32be(3)                    // front cover
        u32be(10); p += Array("image/jpeg".utf8)
        u32be(0)                    // desc len 0
        u32be(512); u32be(512); u32be(24); u32be(0)
        u32be(png.count); p += png
        let data = CoverArt.parseFlacPicture(Data(p))
        XCTAssertEqual(data, Data(png))
    }
}

// MARK: - 设备名义采样率（PCM 匹配模式）

extension PCMFileTests {
    /// 默认输出设备的名义采样率可读且为正；同值设置幂等成功
    func testNominalRateReadWrite() throws {
        guard let dev = AudioDeviceManager.defaultOutputDevice() else { return }
        let rate = AudioDeviceManager.nominalRate(dev)
        XCTAssertNotNil(rate)
        if let rate {
            XCTAssertGreaterThan(rate, 0)
            // 同值写回：不影响系统状态，验证设置通路可用
            XCTAssertTrue(AudioDeviceManager.setNominalRate(dev, rate: rate))
            XCTAssertEqual(AudioDeviceManager.nominalRate(dev) ?? 0, rate, accuracy: 0.5)
        }
    }
}
