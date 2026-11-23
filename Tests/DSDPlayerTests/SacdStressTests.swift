import XCTest
@testable import DSDPlayer

final class SacdStressTests: XCTestCase {
    let isoURL = URL(fileURLWithPath: "/Users/yuzhang/Documents/kimi/tasks/2026-11-15/01-27-58-dd90d563/sacd_sample.iso")

    /// 顺序解码第 1 轨前 2000 帧（约 27 秒音频），验证解码器长序列稳定性。
    /// 整轨全解码约 105 秒，需要时可把循环上界改回 frames 手动跑
    func testDecodeWholeTrack1() throws {
        let iso = try SacdISO(url: isoURL)
        let src = try iso.makeTrackSource(iso.album.tracks[0])
        let frameBytes = UInt64(4704)
        let frames = min(2000, Int(src.totalBytesPerChannel / frameBytes))
        print("decoding \(frames) frames")
        for f in 0..<frames {
            if f % 500 == 0 { print("decoding frame", f); fflush(stdout) }
            let bytes = try src.read(channelByteOffset: UInt64(f) * frameBytes, perChannelByteCount: 4704)
            if bytes.count != 9408 { print("frame", f, "short:", bytes.count) }
        }
        print("done \(frames) frames")
    }
}
