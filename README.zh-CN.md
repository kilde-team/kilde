[English](README.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | [한국어](README.ko.md) | [Español](README.es.md)

# kilde

[![Release](https://github.com/kilde-team/kilde/actions/workflows/release.yml/badge.svg)](https://github.com/kilde-team/kilde/actions/workflows/release.yml)

一款开源的 macOS 屏幕与音频录制工具。

kilde 可以录制屏幕以及 **QuickTime Player 的屏幕录制无法捕捉的系统声音**，
通过单命令 CLI 和菜单栏应用两种方式实现。

本项目拆分为两个仓库（issue #115）：

| 仓库 | 内容 | 可见性 |
|---|---|---|
| [kilde-team/kilde](https://github.com/kilde-team/kilde)（本仓库） | 菜单栏应用（`gui/`）、发布签名与分发、Homebrew formula、文档 | 公开 |
| [kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift) | 录制引擎（`KildeCore`）和 `kilde` CLI 的源代码 | 私有（仅 kilde-team 成员） |

## 功能

- 🖥️ 使用原生 ScreenCaptureKit，零配置即可录制屏幕和系统声音
- 🎤 同时录制麦克风或其他输入设备（如 BlackHole）
  - 默认将多个音源**混音为一条音轨**，也可以用 `--audio-tracks separate`
    分轨保存
- 🪟 **按窗口录制**，系统声音也会限定在该应用，排除通知提示音等其他应用的声音
- 🎙️ 用 `--no-video` 只录音频，无需安装额外的驱动
- 🛡️ 即使按 Ctrl+C 停止录制，也能安全地完成文件的收尾写入
- ⌨️ 通过全局快捷键，在操作其他应用的同时开始/停止录制
- 📝 在设备上将录制内容转写为 markdown / SRT / VTT / 文本 / JSON 的
  sidecar 文件 (macOS 26+)

## 安装

- 需要 macOS 14 或更高版本
- 转写需要 **macOS 26 或更高版本**
- 发布的二进制是 **arm64（Apple Silicon）构建** — 目前不支持 Intel Mac
- 运行时目前是在 Apple Silicon 的 macOS 26 上进行测试
- 构建需要带 macOS 26 SDK 的工具链（引擎引用了 macOS 26 的 API
  `captureHDRRecordingPreservedSDRHDR10`；运行时仍然支持 macOS 14+）

### Mac App Store

菜单栏应用已上架 Mac App Store — 一键安装，由 App Store 自动更新：

<a href="https://apps.apple.com/app/id6812783176">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/appstore/badge/mac-app-store-badge-en-white.svg">
    <img src="docs/appstore/badge/mac-app-store-badge-en-black.svg" alt="在 Mac App Store 下载" height="40">
  </picture>
</a>

### Homebrew

```sh
brew tap kilde-team/kilde
brew trust --formula kilde-team/kilde/kilde   # 仅新版 Homebrew 需要，一次即可
brew install kilde

# 或者直接从 tap 安装
brew install kilde-team/kilde/kilde
```

### 发布的二进制

从 [GitHub Releases](https://github.com/kilde-team/kilde/releases) 下载
`kilde-<版本>-macos.zip`，解压后将 `kilde` 二进制放到 `PATH` 中：

```sh
unzip kilde-*-macos.zip && sudo cp release/kilde /usr/local/bin/
```

### 从源码构建

`kilde` CLI 和 `KildeCore` 引擎在
[kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift)
（**私有仓库**）中开发，目前不提供公开的源码构建 — 请使用 Homebrew 或
发布的二进制。kilde-team 成员可以克隆该仓库并在其中用 `swift build` 构建
（步骤见该仓库的文档）。

## 快速上手

先运行 `doctor`。屏幕录制和麦克风采集需要 macOS 权限，该命令会检查环境，
并对尚未授予的权限给出提示：

```sh
kilde doctor
```

然后录制屏幕和系统声音。按 Ctrl+C 停止并安全地完成文件写入：

```sh
kilde rec demo.mov
```

使用其他命令可以发现可录制的对象、检查录制文件、管理持久的录制默认值：

```sh
kilde devices         # 列出显示器、窗口和音频设备
kilde inspect FILE    # 显示录制文件中的音轨和音频电平
kilde transcribe FILE # 将录制文件转写为 sidecar 文件 (macOS 26+)
kilde config show     # 显示已配置的值和生效的默认值
```

## 录制示例

录制整个屏幕（默认）或屏幕的一部分。`--region` 接受 `x,y,w,h`（点，
左上角为原点）。受 H.264 约束，宽和高会向下取偶数；超出显示范围的区域会在
录制开始前失败（退出码 1），格式错误或小于 2 点的值是参数错误（退出码 64）。
不能与 `--window`、`--no-video` 或 `--preset meeting` 同时使用：

```sh
# 整个屏幕 + 系统声音（默认）
kilde rec demo.mov

# 屏幕的一部分
kilde rec --region 0,0,1280,720 demo.mov
```

录制 Zoom、Google Meet 或 Teams 的会议。meeting 预设会让你选择一个窗口，
然后将与会者的系统声音和你的麦克风混音为一条音轨：

```sh
kilde rec --preset meeting meeting.mov
```

也可以显式添加麦克风、只录音频为 M4A，或将采集限定到特定应用窗口。
`--window` 支持按部分标题、bundle ID 或窗口 ID 匹配；用 `kilde devices`
查看可用窗口。

```sh
# 屏幕 + 系统声音 + 麦克风
kilde rec --audio system --audio mic out.mov

# 只录音频
kilde rec --no-video memo.m4a

# 只录匹配的 Zoom 窗口的声音，排除其他应用
kilde rec --no-video --window zoom meeting.m4a

# 多个窗口录进一个文件。--window 可以多次指定；输出尺寸为整个显示器，
# 窗口以外的区域为黑色
kilde rec --window zoom --window notes demo.mov

# 在全屏录制中隐藏特定应用，例如密码管理器或聊天客户端。
# bundle ID 需要完全匹配 -- 用 `kilde devices` 查询
#   注意：被排除应用的*音频*也会被丢弃。排除会议应用或浏览器会连声音一起
#   丢掉，因此如果只是不想让画面出现，建议改用 --window 只录需要的窗口
kilde rec --exclude-app com.1password.1password --exclude-app com.tinyspeck.slackmacgap demo.mov

# HDR 录制，需要 macOS 15 或更高版本、HDR 显示器和 HEVC。
# 输出为 HEVC Main10 (PQ)；色域跟随系统预设
#   （macOS 26：BT.2020 + HDR10 元数据，15：Display P3）
#   任一条件不满足时，kilde 会按 SDR 录制、说明原因并仍以退出码 0 结束 --
#   不会交给你一个你以为是 HDR 而实际不是的文件
kilde rec --hdr --codec hevc demo.mov
```

要在通过 BlackHole 录制的同时还能听到声音，请安装 BlackHole 并使用
monitor 模式。monitor 模式会在录制会话期间临时创建并撤销所需的
多输出设备。

```sh
brew install --cask blackhole-2ch
kilde rec --no-video --audio "device:BlackHole 2ch" --monitor meeting.m4a
```

让 kilde 以快捷键等待模式启动，用全局的 Cmd+Shift+R 开始和停止录制。
等待中按 Ctrl+C 会直接退出，不生成文件。`--hotkey` 不能与
`--countdown` 同时使用。

```sh
kilde rec --hotkey cmd+shift+r meeting.mov
```

`--duration` *可以*与快捷键同时使用，但计时是从等待结束时开始算 —
而不是从启动时。因此配置文件里的 `hotkey` 会让 `kilde rec --duration 30s`
也进入等待，无人值守的脚本会一直停在那里直到有人按键（Ctrl+C、SIGTERM
和 SIGHUP 都能干净地退出）。当*来自配置文件*的快捷键推迟了你要求的
`--duration` 时，kilde 会向 stderr 输出警告；显式指定的 `--hotkey`
则不提示，因为等待正是你要求的。要无人值守录制，请用
`kilde config unset hotkey` 移除配置中的快捷键。

### 录制后转写

加上 `--transcribe` 后，录制文件完成时会立即转写为 sidecar 文件（`meeting.md`）
(macOS 26+，无需 Speech recognition 权限)：

```sh
kilde rec --transcribe --preset meeting meeting.mov
```

转写完全在你的 Mac 上（设备内）进行 — 音频和转写文本都不会发送到任何地方。
转写只在录制文件完成后才开始，因此失败或中断都不会影响录制本身。在转写进行
中按 Ctrl+C 只会中断转写 — 录制文件仍保留在磁盘上，退出码仍然是 `0`。转写
*失败*（例如不支持的环境或语言、模型下载失败）则以 `1` 退出，因为这是你明确
要求的。`--transcript-format md|srt|vtt|txt|json` 选择 sidecar 格式，
`--locale ja-JP` 选择语言。在 `--no-video --audio-tracks separate` 的录制中，
两条音轨会带说话人标签转写（系统声音轨 = "相手"，麦克风轨 = "自分"）。也可以
用 `kilde transcribe FILE` 转写已有的录制文件。

### 为什么不需要 BlackHole？

kilde 使用 ScreenCaptureKit 的原生系统声音采集，因此普通的屏幕和音频
录制不需要虚拟音频驱动。只有特殊的音频路由（例如 monitor 模式 — 想
边录边听）才需要 BlackHole。

## 录制选项与默认值

默认情况下，kilde 采集 0 号显示器，将 `system` 声音录成 `mixed` 音轨，
视频编码为 H.264，并包含鼠标指针。未指定输出路径时，会生成
`kilde-yyyyMMdd-HHmmss.mp4`（选择 `--format mov` 或 ProRes 强制回退到
`mov` 容器时为 `.mov`；纯音频模式为 `.m4a`）。运行 `kilde rec --help`
查看完整选项列表。

常用选项包括：

- `--display NUMBER` 或 `--window MATCH` 选择采集目标
- 可重复的 `--audio system|mic|device:NAME_OR_UID|none` 选择音源
- `--audio-tracks mixed|separate` 混音或分轨
- `--no-video`、`--monitor`、`--duration 30s`（从快捷键等待结束时计时，
  而非启动时）、`--codec h264|hevc|prores`、`--fps NUMBER`，以及
  `--format mov|mp4`（输出路径的 `.mov`/`.mp4` 扩展名同样决定容器；
  ProRes 不能封装进 MP4，因此单独的 `--codec prores` 会回退到 `mov`）
- `--cursor` 或 `--no-cursor`、`--countdown SECONDS`、`--preset meeting`
  和 `--hotkey SHORTCUT`
- `--transcribe`（与 `--transcript-format`、`--locale` 配合）：录制文件完成后
  将其转写为 sidecar 文件 (macOS 26+)
- `-o PATH` 或 `--output PATH`，位置参数输出路径的替代写法

## 配置

`rec` 的持久默认值保存在 `~/.kilde/config.json`。请用
`kilde config show|set|unset|path` 管理，不要直接手改文件。

```sh
kilde config set outputDirectory ~/Movies/kilde
kilde config set defaultAudioSources system,mic
kilde config set showsCursor false   # 只想这一次显示指针时用 kilde rec --cursor
kilde config set hotkey cmd+shift+r  # 让 rec 以快捷键等待模式启动（见下文的互斥说明）
kilde config set transcribe true     # 每次停止时转写
kilde config set transcriptFormat srt
kilde config set locale ja-JP
kilde config show
kilde config unset hotkey
kilde config path
```

支持的键为 `outputDirectory`、`defaultAudioSources`、`audioTracks`、
`codec`、`format`、`videoBitrate`、`audioBitrate`、`fps`、`showsCursor`、
`hotkey`、`transcribe`、`transcriptFormat` 和 `locale`。

录制设置的解析顺序（从高到低）：

1. CLI 参数
2. `--preset`
3. 环境变量（如 `KILDE_OUTPUT_DIR`）
4. 配置文件
5. 内置默认值

快捷键有自己对应的顺序：`--hotkey`，然后是配置的 `hotkey`，最后是不等待。

全局快捷键同一时刻只能由一个进程持有，因此**先注册的进程获胜**。这在
菜单栏应用运行时很重要 — 它在登录时启动并持有配置的快捷键。当 `rec`
发现快捷键已被占用时，来自配置文件的快捷键会被跳过：它输出警告并立即
开始录制，而不是等待。显式的 `--hotkey` 则会以原因失败，因为等待正是
你要求的。

`rec` 在做决定之前才检查快捷键是否可用，因此如果在这一间隙有进程抢占
了按键，仍会以注册错误退出 — 实际中需要两条录制几乎同时启动才会发生，
因为 GUI 持有的快捷键会被该检查捕获。

设置 `KILDE_CONFIG_DIR` 可以同时迁移 `config.json` 和
`monitor-state.json` 的保存位置，适合隔离环境和测试。其值必须是绝对路径
或以 `~` 开头；相对路径会被拒绝。配置无效或输出目录不存在时，会在录制
开始前失败，退出码为 `1`。

## 退出码

| 退出码 | 含义 |
|---:|---|
| `0` | 成功，包括被 SIGINT、SIGTERM 或 SIGHUP 安全停止的录制。用 Ctrl+C 中断 `rec --transcribe` 的录制后转写同样以 `0` 退出 — 录制文件保留在磁盘上 |
| `1` | 其他运行时错误，包括无效配置。`rec --transcribe` 的录制后转写失败（不支持的环境或语言、模型下载失败、sidecar 写入失败）同样以 `1` 退出 — 录制文件仍在，但转写是你明确要求的 |
| `2` | 缺少权限 |
| `3` | 找不到显示器、窗口或音频设备 |
| `64` | 命令行解析或选项校验错误，例如 `rec --fps 0` |

## GUI

`gui/` 中的菜单栏应用使用 `NSStatusItem` 和 `NSPopover`。之所以用 AppKit
手动管理，是因为 SwiftUI 的 `MenuBarExtra`（`.window` 面板）在 macOS 26
上无法打开。GUI 通过对
[kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift)
（私有 — 包解析需要 kilde-team 的 git 凭据）的**固定 revision** 依赖，
与 CLI 共享同一个 `KildeCore` 录制引擎。未提交的 Xcode 工程由
`project.yml` 用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成：

```sh
brew install xcodegen   # 仅首次需要
cd gui && xcodegen
open KildeGUI.xcodeproj # 在 Xcode 中运行 KildeGUI scheme
```

构建后菜单栏会出现 ● 图标。点击它选择采集目标（屏幕 / 窗口 / 仅音频）、
音源和输出目录，然后开始录制。录制时菜单栏显示已用时间，面板显示各音源
的电平表。关闭面板不会停止录制。初始值与 CLI 一样读取
`~/.kilde/config.json`。

录制结束后，通知会显示文件名、时长和大小；点击通知会在 Finder 中显示该
文件。面板还会列出输出目录中最近的 5 个录制 — 包括用 CLI 录的 — 点击
同样会在 Finder 中显示。可以在面板中设置全局快捷键，从而在任意应用中
开始/停止录制；它作为 `hotkey` 写入同一个配置文件，因此 `kilde rec`
也会读取。复选框通过 `SMAppService` 将应用注册为登录时启动，macOS 可能
会要求你在系统设置中批准。

只有直接分发版（GitHub Releases / Homebrew，或从源码构建）才与 CLI 共享
配置文件。Mac App Store 版运行在 App Sandbox 中，无法读取 `~/.kilde`，
设置保存在应用自己的容器内
（`~/Library/Containers/com.takezou621.KildeGUI/Data/Library/Application Support/kilde/`），
因此初始值、全局快捷键等设置不会与 `kilde rec` 共享。

## 开发

- 引擎和 CLI（`KildeCore`、`kilde`）：在
  [kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift)
  （私有）中开发 — 测试与 CI 也由该仓库负责
- 菜单栏应用、发布 workflow 和 Homebrew formula：本仓库
  - 构建、权限与 GUI 疑难解答：
    [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
  - 正式发布（签名、公证、分发）：
    [docs/RELEASE.md](docs/RELEASE.md)
- 架构与行为：[docs/DESIGN.md](docs/DESIGN.md)
- M0 技术验证结果：[docs/SPIKE-NOTES.md](docs/SPIKE-NOTES.md)
- 变现策略调研（日语）：
  [docs/MONETIZATION.md](docs/MONETIZATION.md)

## 路线图

- **M0** ✅ 技术验证：验证了 ScreenCaptureKit 的音频采集
- **M1** ✅ CLI MVP：`kilde rec / devices / doctor / audio monitor / inspect`
  （引擎与 CLI 源码已迁移至
  [kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift)，
  issue #115）
- **M2** 全局快捷键 ✅；区域录制 ✅；暂停/恢复
- **M3** 菜单栏 GUI 应用：骨架 ✅ / 录制 UI ✅ / 权限引导 ✅ /
  完成通知、最近录制、全局快捷键和登录时启动 ✅

## 名字的由来

*kilde* 是丹麦语和挪威语中表示「**源头**」的词 — 本义是泉水，即从
地下涌出水的地方，引申为信息的来源，例如记者或学者所说的「消息来源」
（source）。

如今越来越多的知识诞生于线上会议和屏幕之中。在 AI 能够对录制内容进行
转写、总结和检索的时代，这些录制 — 视频、音频、屏幕 — 本身就是宝贵的
信息源，而不是会议结束后就丢弃的副产品。kilde 之名源于它存在的意义：
留住源头。出于同样的理念，kilde 保证停止录制 — 即使按 Ctrl+C —
也总会留下一个收尾完成、可以播放的文件。打不开的来源，就不成其为来源。

## 参与贡献

欢迎提交 bug 报告、功能建议和 pull request。入门请参阅
[CONTRIBUTING.md](CONTRIBUTING.md)。录制引擎和 CLI 的开发在
kilde-team/kilde-cli-swift 进行。

## 许可证

[MIT License](LICENSE)
