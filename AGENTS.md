# AGENTS.md — DSDPlayer 项目协作指南

> 本文档是项目约定与隐性知识的单一事实来源，供人类与 AI 协作者阅读。
> 规则按"必须遵守 / 建议 / 背景知识"分级，改动代码前请先读完。

## 项目概况

macOS 原生 DSD 音频播放器（SwiftUI + AUHAL），核心能力：DSF/DFF/SACD-ISO 播放、
DoP 位元直通 USB DAC、DSD→PCM 转换（LUT 加速 + 256 阶 FIR）、三套皮肤。
GitHub: https://github.com/YuZhang/dsd-player ｜ 当前版本 v1.5.0。

## 构建 / 安装 / 测试（必须遵守）

```bash
swift build          # 编译检查
swift test           # 全量测试：32 个，基线 ~90 秒，全部必须通过
./build_app.sh       # release 构建 + 打包 .build/DSDPlayer.app（版本号在脚本内联 plist）
```

安装到 /Applications 的**正确姿势**（直接 `cp -R` 覆盖会破坏代码签名导致 SIGKILL）：

```bash
rm -rf /Applications/DSDPlayer.app
cp -R .build/DSDPlayer.app /Applications/
codesign --force --sign - /Applications/DSDPlayer.app
open -a DSDPlayer
```

DMG 打包：`hdiutil create -volname "DSDPlayer" -srcfolder <含 app + Applications 软链的目录> -ov -format UDZO`。

GitHub Release 注意：本机直连 api.github.com 会超时，`gh` 命令需显式走代理：
`HTTPS_PROXY=http://127.0.0.1:1087 HTTP_PROXY=http://127.0.0.1:1087 gh release create ...`

## Git 约定

- 提交信息用**中文**，描述"做了什么 + 量化结果"
- 功能分支 + `--no-edit -m` 合并回 main（保留分支语义），发布后删分支
- 版本号三处同步：`build_app.sh` 内联 plist、git tag（vX.Y.Z）、Release notes
- 发布流程：README 更新 → tag → swift test 全过 → build → DMG → push main+tag → gh release
- 用户没说"发布/推送"就只做本地提交

## 修改应用状态（savedState）的安全流程（必须遵守）

用户设置与播放列表存在 `~/Library/Preferences/local.dsdplayer.plist` 的
`DSDPlayer.savedState`（JSON）。**直接写文件会被 cfprefsd 缓存覆盖**；正确流程：

1. `pkill -x DSDPlayer`
2. plistlib 读 plist → 修改 JSON 字段 → `defaults write local.dsdplayer DSDPlayer.savedState -data <hex>`
3. 启动应用。务必保留 `paths` 字段——历史上直接操作丢过用户 59 首播放列表

## 架构红线（必须遵守）

- **音频渲染回调（`PlaybackEngine.render`）是 CoreAudio 实时线程**：禁止分配内存、
  禁止锁、禁止任何可能阻塞的调用。VU 电平估计已在此线程，改动时保持无分配
- **引擎操作统一走 `PlayerModel.engineQueue`**（串行队列）：打开文件、AudioUnit 生命周期、
  seek、stop、setNext 全部在此；UI 状态用 @Published 在主线程更新
- **@Published 每次赋值都会发通知**（不管值是否变化）：高频字段（position/meterL/meterR）
  已拆到 `PlayheadState`/`MeterState` 独占订阅，改动时保持"值不变不赋值"的守卫——
  违反此规则会导致空闲 CPU 飙到 36%
- PCM 转换是 1-bit FIR 查找表（`PCMConverter.swift`），滤波器固定 256 阶；
  LUT 与逐位实现有单元测试锁定一致性（`testLUTMatchesDirectFIR`），改滤波器设计时跑它
- DoP 模式是 bit-perfect 卖点：**音频路径上的任何"改进"都不能改动喂给 DAC 的比特**

## 测试基线

- 32 个测试全过才算完；SACD 压力测试已减帧（整轨解码需手动改回循环上界）
- `testLUTPerformance` 输出加速比，LUT 低于 3x 说明回归
- 无 UI 测试；UI 正确性靠下方验收流程

## UI 验收流程（本项目的特殊之处）

用户会**逐像素验收 UI** 且用真机听音。改 UI 后必须：

1. 构建安装启动真实应用
2. 用 kimi-cu（或人工）截图核对；可用 Python PIL 采样像素值做定量验证
   （如半透明背景均匀性、对齐、颜色一致性）
3. 涉及播放的功能需真机冒烟（VU 动画、切歌、seek）
4. 三个皮肤都要过一遍（Default / Braun Retro / Terminal Green 共用令牌，
   但浅色/暗色行为不同）

已知 UI 坑（改前自查）：
- SwiftUI `Menu` + `.borderlessButton` 会忽略 label 的 frame 并把内容居中——
  设备选择控件因此改用了普通 Button + 手动 NSMenu（`showDeviceMenu`），别改回去
- 窗口 `isOpaque = false` + `backgroundColor = .clear`：半透明填充会叠加混合，
  半透明模式下整窗只能由根部背景绘制一次（`isTranslucent` 逻辑）
- 菜单弹出是独立窗口：窗口截图拍不到，用全屏截图 + CGWindowList 定位

## 设计体系

- `design.md`：色板 / 四档字号阶梯（Design.Scale）/ 间距 / 动效令牌 / 三皮肤人格
- 新 UI 元素必须三皮肤兼容，颜色用 theme 令牌，禁止硬编码
- 皮肤人格：Default=精密仪器（黑金等宽数字）、Braun=复古拟物、Terminal=CRT 荧光

## 背景知识（帮助理解，非规则）

- DSD64 原生 2.8224MHz，DSD→PCM 基准率 = DSD率/32（44.1k 家族）
- 用户主力测试文件：Hotel California DFF（实为 44.1k 母带 ΣΔ 调制的 SACD 转录，
  COMT chunk 有 "SACD Ripper" 字样）；多种 DSD64/128/256 文件在 ~/Music/Hifi
- 用户设备：Topping DX5 II（DoP 支持验证过 DSD256→705.6k）、Astell&Kern HC2（DoP 有坑，
  见 11-16 会话记录——HC2 的 DoP 触发过从头播放/声道失衡，未复现）
- 曾经踩过的坑都写在提交历史里，遇到诡异行为先 `git log --oneline` 搜关键词

## 协作风格

- 界面文案英文、代码注释中文、提交信息中文
- 用户消息简短，期望直接动手 + 实机验证，不要长篇征询
- 修改 savedState、删除分支、推送发布前需用户明示
