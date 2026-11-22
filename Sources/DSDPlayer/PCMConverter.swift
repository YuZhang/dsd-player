import Foundation

/// DSD→PCM 转换器：MSB-first DSD 字节流 → 加窗 sinc 低通 → 多相抽取 → Int32 PCM。
/// 抽取率 = DSD率/PCM率（如 DSD64→88.2k 为 32）。
///
/// 1-bit 信号 FIR 的查找表实现：输出采样 = 最近 L 个抽取组（每组 dec 比特）贡献的叠加，
/// 每组的贡献 C[k] = Σ h[k·dec + r]·bit 预计算为 256 项表（按字节值查表）。
/// 每字节约 L 次查表+加法（L = M/dec = 8），比逐位乘加（每字节 8L 次）快约 5 倍；
/// 同时消除了逐字节拷贝整个历史缓冲的开销。
final class DSDToPCM {
    let decimation: Int
    private let taps: [Float]
    private let L: Int          // 滤波器覆盖的抽取组数 = taps.count / decimation
    private let slots: Int      // 每组字节数 = decimation / 8

    /// 查找表：lut[字节槽][字节值][k] = 该字节对滞后 k 个输出组的贡献
    private let lut: [[[Float]]]

    /// 每声道：当前组的累积贡献（部分和）与最近 L 组的贡献环形缓冲
    private var partial: [[Float]]
    private var ring: [[[Float]]]
    private var groupIndex: [Int]     // 每声道已完成的组数
    private var byteInGroup: [Int]    // 每声道当前组内字节序号

    /// 逐位直接实现（decimation 非 8 的倍数时回退，及测试对照用）
    private let direct: DirectFIR?

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

        L = M / decimation
        if decimation % 8 == 0, L * decimation == M {
            slots = decimation / 8
            // 预计算查找表：lut[t][v][k] = 字节 t 的值 v 对滞后 k 个输出组的贡献。
            // 与逐位实现对齐：输出 y[i] 以比特 i·dec-1 为最新点，
            // 组 m 内位置 q 的比特由 taps[k·dec + (dec-1) - q] 加权（组内反序）
            var table = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: L), count: 256), count: slots)
            for t in 0..<slots {
                for v in 0..<256 {
                    var row = [Float](repeating: 0, count: L)
                    for b in 0..<8 {
                        let q = t * 8 + b
                        let bit = (v >> (7 - b)) & 1 == 1 ? Float(1) : Float(-1)
                        for k in 0..<L {
                            row[k] += taps[k * decimation + (decimation - 1) - q] * bit
                        }
                    }
                    table[t][v] = row
                }
            }
            lut = table
            direct = nil
        } else {
            slots = 0
            lut = []
            direct = DirectFIR(taps: taps, decimation: decimation, channels: channels)
        }
        partial = [[Float]](repeating: [Float](repeating: 0, count: L), count: channels)
        ring = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: L), count: L), count: channels)
        groupIndex = [Int](repeating: 0, count: channels)
        byteInGroup = [Int](repeating: 0, count: channels)
    }

    /// 输入按声道交错的 MSB-first DSD 字节，输出交错 Int32 PCM（增益留 1.5dB 余量防削波）。
    func process(_ dsd: [UInt8], channels: Int) -> [Int32] {
        if let direct {
            return direct.process(dsd, channels: channels)
        }
        var out = [Int32]()
        out.reserveCapacity(dsd.count * 8 / decimation)
        for (i, byte) in dsd.enumerated() {
            let c = i % channels
            var p = partial[c]
            let t = byteInGroup[c]
            let row = lut[t][Int(byte)]
            for k in 0..<L {
                p[k] += row[k]
            }
            byteInGroup[c] = t + 1
            if byteInGroup[c] == slots {
                // 组完成：贡献入环，若历史足够则输出一个采样
                byteInGroup[c] = 0
                partial[c] = [Float](repeating: 0, count: L)
                var g = groupIndex[c]
                ring[c][g % L] = p
                g += 1
                groupIndex[c] = g
                // 每组完成即输出（与逐位实现一致：早期输出以零填充历史）
                var y: Float = 0
                let r = ring[c]
                for k in 0..<L {
                    let m = g - 1 - k
                    if m >= 0 { y += r[m % L][k] }
                }
                let scaled = y * 0.85 * Float(0x1p31)
                out.append(Int32(max(-Float(0x1p31), min(Float(0x1p31) - 1, scaled))))
            } else {
                partial[c] = p
            }
        }
        return out
    }
}

/// 逐位直接实现（LUT 路径的对照与回退）
final class DirectFIR {
    let taps: [Float]
    let decimation: Int
    private var history: [[Float]]
    private var histPos: [Int]
    private var bitCount: [UInt64]

    init(taps: [Float], decimation: Int, channels: Int) {
        self.taps = taps
        self.decimation = decimation
        let M = taps.count
        history = [[Float]](repeating: [Float](repeating: 0, count: M + 1), count: channels)
        histPos = [Int](repeating: 0, count: channels)
        bitCount = [UInt64](repeating: 0, count: channels)
    }

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
