import XCTest
@testable import DSDPlayer

final class SacdAllTracksTests: XCTestCase {
    let isoURL = URL(fileURLWithPath: "/Users/yuzhang/Documents/kimi/tasks/2026-11-15/01-27-58-dd90d563/sacd_sample.iso")

    /// 所有 14 轨各解码前 300 帧，定位异常帧
    func testAllTracks() throws {
        let iso = try SacdISO(url: isoURL)
        for t in iso.album.tracks {
            print("== track \(t.index + 1) \(t.title)")
            fflush(stdout)
            let src = try iso.makeTrackSource(t)
            for f in 0..<300 {
                let bytes = try src.read(channelByteOffset: UInt64(f) * 4704, perChannelByteCount: 4704)
                if bytes.count != 9408 { print("short read at track \(t.index+1) frame \(f)") }
            }
            print("track \(t.index + 1) ok")
        }
    }
}
