#!/usr/bin/env python3
"""生成 DSD 测试音源: 二阶 sigma-delta 调制, 立体声 (左 440Hz / 右 880Hz), DSF 格式。
用法: python3 make_test_tone.py <输出.dsf> [DSD倍数 64/128/256] [秒数]"""
import struct, math, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "test_tone_dsd64.dsf"
MULT = int(sys.argv[2]) if len(sys.argv) > 2 else 64
SECONDS = int(sys.argv[3]) if len(sys.argv) > 3 else 10
RATE = 44100 * MULT
BLOCK = 4096

def sigma_delta(freq, amp, seconds):
    """二阶 sigma-delta 调制 (噪声整形到超声段), 输出 0/1 比特"""
    n = int(RATE * seconds)
    bits = bytearray(n)
    s1 = s2 = 0.0
    q = 1.0
    for i in range(n):
        x = amp * math.sin(2 * math.pi * freq * i / RATE)
        s1 += (x - q)
        s2 += (s1 - q)
        q = 1.0 if s2 >= 0 else -1.0
        bits[i] = 1 if q > 0 else 0
    return bits

def pack_lsb_first(bits):
    """DSF: 每字节 LSB-first (bit0 = 最早时刻)"""
    out = bytearray((len(bits) + 7) // 8)
    for i, b in enumerate(bits):
        if b:
            out[i >> 3] |= 1 << (i & 7)
    return bytes(out)

def channel_data(freq, amp):
    data = pack_lsb_first(sigma_delta(freq, amp, SECONDS))
    # 补齐到块整数倍 (0x69 = DSD 静音)
    pad = (-len(data)) % BLOCK
    return data + b"\x69" * pad

left = channel_data(440.0, 0.5)
right = channel_data(880.0, 0.35)   # 右声道 880Hz, 便于分辨声道

# 块交错: [块0 L][块0 R][块1 L][块1 R]...
payload = bytearray()
for off in range(0, len(left), BLOCK):
    payload += left[off:off + BLOCK]
    payload += right[off:off + BLOCK]

sample_count = SECONDS * RATE
fmt_body = struct.pack("<IIIIIIQI", 1, 0, 2, 2, RATE, 1, sample_count, BLOCK) + b"\x00" * 4
fmt_chunk = b"fmt " + struct.pack("<Q", 12 + len(fmt_body)) + fmt_body
data_chunk = b"data" + struct.pack("<Q", 12 + len(payload)) + bytes(payload)
file_size = 28 + len(fmt_chunk) + len(data_chunk)
dsd_chunk = b"DSD " + struct.pack("<QQQ", 28, file_size, 0)

with open(OUT, "wb") as f:
    f.write(dsd_chunk + fmt_chunk + data_chunk)
print(f"已生成 {OUT}: DSD{MULT} 立体声 {SECONDS}s, 左 440Hz / 右 880Hz, {file_size/1e6:.1f} MB")
