# 开发与构建

## 环境

- macOS 14 或更新版本。
- Xcode / Swift 5.10 或更新版本。
- Swift Package Manager 自动解析锁定的 GRDB 7.0.0；首次构建需要网络，应用运行不需要网络。

可以用 Xcode 打开 `LittleEars.xcodeproj`，选择 LittleEars scheme 后运行；也可打开 `Package.swift`。

## 命令行构建

```sh
swift test
scripts/build-app.sh release
open "build/Little Ears.app"
```

构建脚本生成当前机器架构的本地签名应用，不包含 Developer ID 签名、公证或通用架构打包。

## 真实音乐库测试

```sh
LITTLE_EARS_TEST_LIBRARY=/path/to/music swift test
```

可选音乐库测试使用独立数据库，不改写实际应用的音乐库、播放列表和历史记录。

## 界面预览

```sh
swift build
.build/debug/LittleEars --render-preview build/ui-previews
.build/debug/LittleEars --render-preview build/ui-previews --preview-library /path/to/music
.build/debug/LittleEars --render-preview build/motion-preview --preview-library /path/to/music --spectrum-motion
```

预览使用实际 SwiftUI 视图和独立内存数据库。指定音乐库时，频谱取自真实 PCM 数据，测试播放列表只存在于内存。

## 工程文档

- [行为与设计决策](DECISIONS.md)
- [视觉系统及验证记录](UI_DESIGN.md)
- [导航性能与点击命中记录](PERFORMANCE.md)

`--spectrum-motion` 额外生成真实播放器视图的 GIF 和逐帧 FFT 数值 JSON，覆盖开始、暂停、恢复、跳转及切歌。输出静音，分析使用音量调节前 PCM；GIF 是低帧率采样预览，不能当作实际渲染帧率的测量。

## 使用真实历史生成新功能预览

```sh
.build/debug/LittleEars --render-preview build/features-previews --preview-history "$HOME/Library/Application Support/LittleEars/library.sqlite"
```

源数据库以只读方式打开，经 SQLite 在线备份复制到内存；后续初始化及预览操作只作用于副本。功能查询与测试说明见 [FEATURES.md](FEATURES.md)。
