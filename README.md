# MacPlayer

MacPlayer 是一个开源的 macOS 播放器：Apple Silicon arm64，macOS 13.0+，暂不签名。

目标：用最小的资源，流畅播放市面上绝大多数视频格式（MP4、MKV、WebM、AVI、FLV、WMV 等），带播放列表、字幕、倍速、截图和在线字幕搜索。

> 与 PotPlayer / Kakao 无任何关联。MacPlayer 是独立的 clean-room 实现，不含 PotPlayer 的任何二进制、资源或商标。

## 播放引擎：libmpv（LGPL）

- 引擎是 **libmpv 的 LGPL 构建**：`meson -Dgpl=false`，FFmpeg 用 `--disable-gpl` 构建。
- 渲染管线：`vo=gpu-next` + `gpu-api=vulkan` + `gpu-context=moltenvk` + `hwdec=videotoolbox`，硬件解码零拷贝，libplacebo 做缩放和 HDR 色调映射，libass 渲染 ASS 字幕。
- 硬解状态以 libmpv 报告的 `hwdec-current` 为准，`videotoolbox` 失败时自动切到 `videotoolbox-copy`。
- 许可证合规：引擎以独立的动态库形式放在 `MacPlayer.app/Contents/Frameworks/`，install name 为 `@rpath`，用户可以替换兼容的库；构建脚本在 `scripts/build-deps.sh` 里，许可证文本在发布包的 `Contents/Resources/LICENSES/` 里。MacPlayer 自身的代码是 MIT（见 `LICENSE`）。
- 不要抄 IINA 的代码：IINA 是 GPL-3.0，MacPlayer 只参考了它的架构思路（Swift 界面 + libmpv），代码全部自己写。

为什么不用 AVFoundation：它播不了 MKV、WebM、AVI，不支持 DTS/TrueHD 和 ASS/PGS 字幕，做不了 PotPlayer 的替代品。

## 功能

- 播放 / 暂停、进度条、音量、上一曲 / 下一曲、播放结束自动下一曲
- 播放列表：左侧列表，双击播放，拖放文件 / 文件夹，持久化到 `~/Library/Application Support/MacPlayer/playlist.json`
- 字幕：本地同名 `.srt/.ass` 自动加载（libmpv `sub-auto=fuzzy`）；在线搜索见下；字幕延迟可调
- 倍速：0.25x–2x
- 截图：当前帧存为 PNG 到 `~/Pictures/MacPlayer/MacPlayer-YYYYMMDD-HHmmss.png`
- 快捷键：Space 播放/暂停、左右方向键 ±5 秒、上下方向键音量、F 全屏、S 截图、N 下一曲、P 上一曲

## 字幕：默认顺序

1. **本地同名文件**：与视频同名、同目录或 `sub/` 目录下的 `.srt/.ass`，离线可用，最可靠。
2. **OpenSubtitles.com**：REST v1（`api.opensubtitles.com`），moviehash 精确匹配优先，标题次之。需要用户自己在设置里填 API Key。
3. **Assrt（伪射手网，assrt.net）**：中文默认源，仅在语言含中文时默认开启。REST（`api.assrt.net`），需要用户自己注册后在设置里填 32 位 token。
4. **SubDL**：REST（`api.subdl.com`），全球备用源，免费 key 每天 50 次下载。需要用户自己填 API Key。

- 三个在线源的 key/token 一律由用户在设置里自己填，存在本机钥匙串，代码和仓库里没有任何共享 key。
- 排名：hash 匹配 > 发行组匹配 > 下载量/评分 > 语言偏好。搜索 5 秒超时，失败自动降级到下一个源，绝不阻塞播放。
- 下载后存为 `<视频名>.<语言>.srt` 到视频同目录，再用 libmpv 的 `sub-add` 加载；ZIP 用系统 `unzip` 解开，RAR/7z 不支持。
- **不在默认源里**：字幕库（Zimuku）、SubHD——没有公开接口，只能爬虫，还带验证码/墙，只能做可选插件，本版未实现；射手网（Shooter，2014 年停运）、Subscene（2024 年 5 月停运）——已死，不列入。
- 字幕是他人的翻译作品：本程序不托管、不缓存、不分发字幕文件，只下载用户自己选中的那一份到用户自己的磁盘。

## 从源码构建（macOS arm64）

```sh
./scripts/build-deps.sh   # 编译 LGPL FFmpeg + libmpv 到 deps/
./build.sh                # 编译 Swift 代码，产出 MacPlayer.app
```

注意：`scripts/build-deps.sh` 里的 FFmpeg / mpv 版本已 pin 死，SHA256 是占位符——发布前请用实测值填入（`shasum -a 256 <文件>`），脚本填入后会校验下载。

发布：在 GitHub 上打 tag `v1.0.0` 之类的，Actions 会在 `macos-14` 上跑上面两步，生成 `MacPlayer-v1.0.0-macos-arm64.dmg` 并发布到 Releases。

## 未签名应用怎么打开

MacPlayer 暂不签名（没有 $99/年的 Apple Developer Program 账号）。从网上下载后，macOS Gatekeeper 可能会拦截：

1. 右键点击 `MacPlayer.app` → 选择“打开”，再点“打开”；
2. 或者在“系统设置 → 隐私与安全性”里点“仍要打开”；
3. 或者在终端执行：`xattr -cr /Applications/MacPlayer.app`

不要全局关闭 Gatekeeper / SIP。

## 目录结构

```
Sources/CMPV/            libmpv C 头封装（module.modulemap + shim.h）
Sources/MacPlayer/
  main.swift             入口
  AppDelegate.swift      菜单、打开文件
  MPVPlayer.swift        libmpv 封装（wid 渲染，见文件头注释）
  PlayerWindowController.swift   主窗口、播放列表、控制条
  SettingsWindowController.swift 设置、在线字幕搜索窗口
  PlaylistStore.swift    播放列表持久化
  SubtitleParser.swift   SRT/VTT 解析
  SubtitleDownloader.swift       字幕 Provider、moviehash、Keychain
  Screenshot.swift       libmpv 截图
scripts/build-deps.sh    编译 LGPL FFmpeg + libmpv
build.sh                 编译 MacPlayer.app（swiftc）
.github/workflows/release.yml   tag 触发，编译并发布 .dmg
```
