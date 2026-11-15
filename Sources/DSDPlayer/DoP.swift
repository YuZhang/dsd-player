import Foundation
import Synchronization

/// DoP (DSD over PCM) v1.1 编码器。
/// 每个 24-bit PCM 帧: 最高字节 = 标记 (0x05 / 0xFA 逐帧交替)，低 16 位 = 16 个 DSD bit。
/// 输入字节须为 MSB-first（DSF 已在解析层反转；DFF 原生 MSB-first）。
/// 输出为左对齐到 32-bit 容器的 Int32 采样（字节序: [pad, dsd_b1, dsd_b0, marker]）。
struct DoPEncoder {
    private var markerPhase = 0  // 0 -> 0x05, 1 -> 0xFA

    mutating func reset() { markerPhase = 0 }

    /// dsd: 按 [ch0b0, ch1b0, ch0b1, ch1b1, ...] 逐字节交错的数据，长度须为 2*channels 的倍数。
    mutating func encode(_ dsd: [UInt8], channels: Int) -> [Int32] {
        let frames = dsd.count / (2 * channels)
        var out = [Int32]()
        out.reserveCapacity(frames * channels)
        for f in 0..<frames {
            let marker: UInt32 = markerPhase == 0 ? 0x05 : 0xFA
            for c in 0..<channels {
                // 每声道每帧取该声道连续的 2 个字节（注意输入是按字节交错的）
                let b0 = UInt32(dsd[(2 * f) * channels + c])
                let b1 = UInt32(dsd[(2 * f + 1) * channels + c])
                let word = (marker << 24) | (b0 << 16) | (b1 << 8)
                out.append(Int32(bitPattern: word))
            }
            markerPhase ^= 1
        }
        return out
    }

    /// DoP 静音帧（DSD 静音码 0x69），用于欠载/暂停时保持标记不断流。
    mutating func silence(frames: Int, channels: Int) -> [Int32] {
        var out = [Int32]()
        out.reserveCapacity(frames * channels)
        for _ in 0..<frames {
            let marker: UInt32 = markerPhase == 0 ? 0x05 : 0xFA
            let word = (marker << 24) | (0x69 << 16) | (0x69 << 8)
            for _ in 0..<channels { out.append(Int32(bitPattern: word)) }
            markerPhase ^= 1
        }
        return out
    }
}

/// 单生产者单消费者无锁环形缓冲（Int32 采样）。
/// 生产者 = 喂数据线程，消费者 = CoreAudio 渲染回调（实时线程，不可阻塞）。
final class RingBuffer: @unchecked Sendable {
    let capacity: Int
    private let buffer: UnsafeMutablePointer<Int32>
    private let writeIndex = Atomic<Int>(0)  // 单调递增，取模定位
    private let readIndex = Atomic<Int>(0)

    init(capacity: Int) {
        precondition(capacity > 0 && (capacity & (capacity - 1)) == 0)
        self.capacity = capacity
        buffer = .allocate(capacity: capacity)
    }

    deinit { buffer.deallocate() }

    var availableToRead: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring)
    }
    var availableToWrite: Int { capacity - availableToRead }

    func clear() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
    }

    @discardableResult
    func write(_ samples: [Int32]) -> Int {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let space = capacity - (w - r)
        let n = min(samples.count, space)
        guard n > 0 else { return 0 }
        let off = w & (capacity - 1)
        let first = min(n, capacity - off)
        buffer.advanced(by: off).initialize(from: samples, count: first)
        if n > first {
            buffer.initialize(from: Array(samples[first..<n]), count: n - first)
        }
        writeIndex.store(w + n, ordering: .releasing)
        return n
    }

    /// 读取 n 个采样到指针，返回实际读取数。
    @discardableResult
    func read(into dest: UnsafeMutablePointer<Int32>, count n: Int) -> Int {
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .relaxed)
        let avail = w - r
        let count = min(n, avail)
        guard count > 0 else { return 0 }
        let off = r & (capacity - 1)
        let first = min(count, capacity - off)
        dest.update(from: buffer.advanced(by: off), count: first)
        if count > first {
            dest.advanced(by: first).update(from: buffer, count: count - first)
        }
        readIndex.store(r + count, ordering: .releasing)
        return count
    }
}
