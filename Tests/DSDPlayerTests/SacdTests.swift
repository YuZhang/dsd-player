import XCTest
@testable import DSDPlayer

final class SacdTests: XCTestCase {
    // 样本 ISO 位于工作区根目录（约 1GB，不入库）
    let isoURL = URL(fileURLWithPath: "/Users/yuzhang/Documents/kimi/tasks/2026-11-15/01-27-58-dd90d563/sacd_sample.iso")

    func testParseAlbum() throws {
        let iso = try SacdISO(url: isoURL)
        XCTAssertEqual(iso.album.trackCount, 14)
        XCTAssertEqual(iso.album.channelCount, 2)
        XCTAssertTrue(iso.album.dstEncoded)   // 此盘为 DST 压缩
        for t in iso.album.tracks {
            print("Track \(t.index + 1): \(t.title) — \(t.performer), \(String(format: "%.1f", t.durationSeconds))s, LSN \(t.startLSN)+\(t.lengthLSN)")
        }
    }

    func testDecodeFirstFrame() throws {
        let iso = try SacdISO(url: isoURL)
        let src = try iso.makeTrackSource(iso.album.tracks[0])
        let bytes = try src.read(channelByteOffset: 0, perChannelByteCount: 4704)
        XCTAssertEqual(bytes.count, 9408)   // 2ch × 4704
        // 解码成功不应全是静音填充
        XCTAssertFalse(bytes.allSatisfy { $0 == 0x69 }, "decoded frame is all silence padding")
        print("first 16 bytes:", bytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))
    }

    func testSeekMidTrack() throws {
        // 跳到曲目中段（第 60 秒附近）读取，验证随机访问
        let iso = try SacdISO(url: isoURL)
        let src = try iso.makeTrackSource(iso.album.tracks[0])
        let off = UInt64(60 * 2_822_400 / 8)   // 60 秒 × 字节率
        let bytes = try src.read(channelByteOffset: off, perChannelByteCount: 8192)
        XCTAssertEqual(bytes.count, 16384)
        XCTAssertFalse(bytes.allSatisfy { $0 == 0x69 }, "seek decode produced silence")
        print("mid-track bytes:", bytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))
    }

    func testLastTrack() throws {
        // 最后一首的末尾读取
        let iso = try SacdISO(url: isoURL)
        let last = iso.album.tracks.last!
        let src = try iso.makeTrackSource(last)
        let total = src.totalBytesPerChannel
        let bytes = try src.read(channelByteOffset: total - 4096, perChannelByteCount: 2048)
        XCTAssertEqual(bytes.count, 4096)
    }
}
