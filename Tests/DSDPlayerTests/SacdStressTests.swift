import XCTest
@testable import DSDPlayer

final class SacdStressTests: XCTestCase {
    let isoURL = URL(fileURLWithPath: "/Users/yuzhang/Documents/kimi/tasks/2026-11-15/01-27-58-dd90d563/sacd_sample.iso")

    /// 顺序解码整个第 1 轨，定位崩溃帧
    func testDecodeWholeTrack1() throws {
        let iso = try SacdISO(url: isoURL)
        let src = try iso.makeTrackSource(iso.album.tracks[0])
        let total = src.totalBytesPerChannel
        let frameBytes = UInt64(4704)
        let frames = Int(total / frameBytes)
        print("total frames:", frames)
        for f in 0..<frames {
            if f % 500 == 0 { print("decoding frame", f); fflush(stdout) }
            let bytes = try src.read(channelByteOffset: UInt64(f) * frameBytes, perChannelByteCount: 4704)
            if bytes.count != 9408 { print("frame", f, "short:", bytes.count) }
        }
        print("done all frames")
    }
}
