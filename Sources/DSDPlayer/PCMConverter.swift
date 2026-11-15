import Foundation

/// DSD→PCM 转换器：MSB-first DSD 字节流 → 加窗 sinc 低通 → 多相抽取 → Int32 PCM。
/// 抽取率 = DSD率/PCM率（如 DSD64→88.2k 为 32）。多相结构只在输出点计算 FIR，CPU 开销小。
final class DSDToPCM {
    let decimation: Int
    private let taps: [Float]
    private var history: [[Float]]   // 每声道环形历史
    private var histPos: [Int]
    private var bitCount: [UInt64]   // 每声道已处理比特数

    init(dsdRate: UInt32, pcmRate: Int, channels: Int) {
        decimation = Int(dsdRate) / pcmRate
        let M = 8 * decimation                       // 滤波器阶数
        let fc = min(24_000.0, Double(pcmRate) * 0.45) / Double(dsdRate)
        var h = [Float](repeating: 0, count: M + 1)
        var sum: Float = 0
        for n in 0...M {
            let k = Float(n) - Float(M) / 2
            let sinc = k == 0 ? Float(2 * fc)
                              : sin(Float.pi * 2 * Float(fc) * k) / (Float.pi * k)
            // Blackman 窗
            let w = Float(0.42 - 0.5 * cos(2 * Double.pi * Double(n) / Double(M))
                                + 0.08 * cos(4 * Double.pi * Double(n) / Double(M)))
            h[n] = sinc * w
            sum += h[n]
        }
        taps = h.map { $0 / sum }
        history = [[Float]](repeating: [Float](repeating: 0, count: M + 1), count: channels)
        histPos = [Int](repeating: 0, count: channels)
        bitCount = [UInt64](repeating: 0, count: channels)
    }

    /// 输入按声道交错的 MSB-first DSD 字节，输出交错 Int32 PCM（增益留 1.5dB 余量防削波）。
    func process(_ dsd: [UInt8], channels: Int) -> [Int32] {
        var out = [Int32]()
        out.reserveCapacity(dsd.count * 8 / decimation)
        let M = taps.count
        for (i, byte) in dsd.enumerated() {
            let c = i % channels
            var hist = history[c]
            var pos = histPos[c]
            var cnt = bitCount[c]
            for bit in stride(from: 7, through: 0, by: -1) {
                let s: Float = (Int(byte) >> bit) & 1 == 1 ? 1 : -1
                hist[pos] = s
                pos = (pos + 1) % M
                cnt += 1
                // 每隔 decimation 比特输出一个 PCM 采样
                if cnt % UInt64(decimation) == 0 {
                    var y: Float = 0
                    var idx = pos - 1
                    if idx < 0 { idx = M - 1 }
                    for j in 0..<M {
                        y += taps[j] * hist[idx]
                        idx -= 1
                        if idx < 0 { idx = M - 1 }
                    }
                    let scaled = y * 0.85 * Float(0x1p31)
                    out.append(Int32(max(-Float(0x1p31), min(Float(0x1p31) - 1, scaled))))
                }
            }
            history[c] = hist
            histPos[c] = pos
            bitCount[c] = cnt
        }
        return out
    }
}
