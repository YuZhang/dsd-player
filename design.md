# DSDPlayer 设计令牌

UI 审美的单一事实来源。修改样式时优先改这里对应的常量，不要散落硬编码。

## 色彩

| 令牌 | 值 | 用途 |
|---|---|---|
| `Theme.bgTop/bgBottom` | 各皮肤定义 | 面板/列表背景 |
| `Theme.accent` | Default `#EDB54D` / Braun 橙 / Terminal 绿 | 强调色：激活控件、VU、编号 |
| `Theme.badgeBg` | 各皮肤定义 | 徽标底色、未点亮段 |
| 次要文字 | `.secondary` / `.tertiary` | 说明文字 |
| 分隔线 | 皮肤内 `white.opacity(0.06~0.08)` | 列表行分隔 |

深色皮肤文字对比度均 ≥ 4.5:1。新颜色先在此登记再使用。

## 字号阶梯（`Design.Scale`）

全应用只用四档语义层级，不要发明第五档：

| 层级 | 字号 | 用途 |
|---|---|---|
| display | `title3.weight(.semibold)` ≈20 | 歌名 |
| body | `.body` | 列表行、正文 |
| caption | `.caption` ≈12 | 格式信息、时间 |
| micro | `.caption2` ≈11 | 仪器微标签（BIT-PERFECT 等，英文全大写 + tracking 1.2） |

数字（时间/采样率/电平）一律等宽字体；Terminal 皮肤歌名用 Menlo。

## 间距

8pt 网格：`4 / 8 / 12 / 16 / 20 / 28`。面板边距 20，列表行高 34，封面与右栏间距 12。

## 动效（`Design`）

| 令牌 | 值 | 用途 |
|---|---|---|
| `motionStandard` | easeOut 150ms | 悬停、按下 |
| `motionTheme` | spring 250ms | 皮肤切换、播放列表展开收起 |

Bit-Perfect 呼吸灯周期 1.6s；VU 电平 20Hz 刷新（衰减系数按帧率换算）。

## 皮肤人格

- **Default**：精密仪器（黑金、克制、等宽数字）
- **Braun Retro**：博朗复古（奶油拟物、冲孔面板）
- **Terminal Green**：CRT 终端（荧光绿、液晶数字、扫描线）

新元素要能在三种人格下都成立：形状用主题令牌，不写死颜色。
