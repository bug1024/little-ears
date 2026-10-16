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

## 本地水族箱构建

```sh
bash scripts/build-app.sh release --aquarium
```

此命令从本地 `local-assets/MarineAquarium3` 验证并转换资源，写入被忽略的 app 构建产物 `Contents/Resources/AquariumAssets`。源代码与原始素材分离，普通 `swift build`、`swift test` 和 Xcode 工程不要求此目录存在；无资源版本会在水族箱区域显示提示，其他播放器功能正常。

Xcode 工程已包含共用 Swift 渲染代码及 Shaders 资源文件夹。需要检查带场景资源的完整应用时，使用上述打包命令；不要把本地素材直接加入 Xcode 工程或 Git。正式发布前另行处理素材授权／替换。

`Sources/LittleEars/Aquarium/` 包含渲染、模拟和音效代码；`scripts/aquarium-assets/` 包含打包所需的资源转换器与格式校验测试。偏好保存在 UserDefaults 的 `aquarium.configuration.v1`，播放画面选择为 `playingVisualization`。

沉浸模式在同一主窗口中替换布局并使用 AppKit 原生全屏；`AquariumFullScreenSession` 保留进入前的全屏状态，处理转换期间退出及系统全屏退出。主窗口与沉浸布局复用场景控制器，以展示实例标识防止旧视图的延迟移除暂停新视图。全屏状态不跨启动保存。气泡音快捷开关只修改当前配置的音效启用字段并立即持久化。

资源转换测试：

```sh
python3 -m unittest discover -s scripts/aquarium-assets -p 'test_*.py'
swift test --filter AquariumTests
```

场景转换对原始礁石、沙床和前沿砂层使用同一比例与坐标变换，保留各物体的原始相对位置。相机中心与鱼群活动范围由 `AquariumLayout` 对齐。

GPU 绘制测试使用上述打包命令生成的场景资源；未提供资源或 Metal 设备时自动跳过，不依赖独立试验应用。

气泡在中间偏右位置以 160 个独立实例绘制，按各自速度上升并轻微横向漂移；细环、高光与透明中心由着色器生成，不再连续铺设密集气泡贴图。气泡受场景深度遮挡，稀疏悬浮微粒单独绘制。鱼体光纹采用原始 Fish 顶点／片元着色器中的两次采样加法结构，光源方向与强度按当前场景校准，不代表已恢复原程序全部运行参数或动画。
