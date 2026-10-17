# 发布前性能采样

仅用于本机开发测试。正常应用不启动这些采样；测试使用独立 bundle ID、SQLite 在线备份副本和独立偏好，系统播放控制关闭。原始音频只读，音量在 PCM 分析后的 mixer 静音，解码、FFT 与真实绘制继续运行。

## 准备

先构建 Release。复制带水族箱资源的 app 到被 Git 忽略的测试目录，替换为最新 Release 可执行文件，并将复制品的 `CFBundleIdentifier` 改为以 `.performance` 结尾的独立标识后重新本地签名。不要修改正式应用的 bundle ID 或偏好。

在已创建的空测试目录下启动复制品的可执行文件：

```sh
"/path/to/Little Ears Performance.app/Contents/MacOS/LittleEars" \
  --performance-session /absolute/path/to/empty-session \
  --performance-history "/absolute/path/to/source/library.sqlite"
```

`--performance-history` 是只读备份来源；备份复制到测试目录的 `library.sqlite`，随后所有读写针对副本。每次新测试使用空目录，不重用或覆盖需要保留的测试结果。此模式要求隔离 bundle ID，否则退出。隔离签名无法解析原目录书签时，仅测试模式可按原目录路径只读访问音频；不回写原书签。这项测试不验证正式签名下的目录授权。

## 采样

```sh
clang -O2 scripts/performance/sample-process.c -o /path/to/sample-process
python3 scripts/performance/collect.py --session /absolute/path/to/empty-session \
  --pid APP_PID --sampler /path/to/sample-process
python3 scripts/performance/summarize.py /absolute/path/to/empty-session
```

通过原生 UI 切换场景；切换前将测试目录 `phase.txt` 设为 `transition_...`，场景稳定后改为测量名称。工具只采样，不发送键盘鼠标事件。对稳态场景建议预热 10 秒后至少采样 45～60 秒，另做持续运行和重复切换测试。诊断工具的采样开销应单独标记，避免混入稳态结果。

- `sample-process.c` 每秒读取 libproc 的进程 CPU、RSS、physical footprint、唤醒、page-in、磁盘 I/O 及可用的能量计数。CPU 的 Mach ticks 通过 `mach_timebase_info` 转为纳秒；100% 表示占满一个核，不是整台机器。
- `PerformanceSession.swift` 写入每秒运行状态，包含实际 Metal 完成帧数、GPU command 耗时、场景分辨率、播放进度、温度状态及主线程定时器间隔。50 ms 心跳、1 Hz 文件写入及 Metal 完成回调自身有开销；其 CPU、唤醒和写盘包含在结果中，不冒充无仪器的正式包数据。
- `collect.py` 将内核计数与运行状态写入 `samples.jsonl`，状态快照有约一秒时间偏差。`summarize.py` 默认排除各阶段前 10 秒与过期快照，结果为 `summary.json`。转换阶段和诊断阶段应单独读取，不能计入稳态结论。
- GPU 耗时只覆盖本应用的水族箱 Metal command，不含系统合成和频谱 Canvas；完成帧率不是屏幕实际呈现帧率。主线程定时器间隔不是输入到显示延迟。
- 内核能量计数不等于应用总耗电，覆盖范围与校准需另行验证；零值也可能表示不支持。若无管理员权限，不能用它代替 `powermetrics` 的 CPU/GPU 测量或受控续航测试。整机电池放电受屏幕及其他进程影响，不能直接归因于 Little Ears。

测试报告应保留硬件、构建版本、场景参数、采样时长和限制。不要把其他应用的背景负载、已有内存压缩或掉电速度归因于被测应用；不要把一次平稳曲线当作无泄漏证明。完整歌词、原始资料库和缓存不提交到 Git。


## 组件与规模测试

GPU 组件测试依赖已生成的 `build/Little Ears.app/Contents/Resources/AquariumAssets`。其余性能测试还要求输出目录中预先存在通过只读在线备份得到的 `source-snapshot.sqlite`：

```sh
LITTLE_EARS_PERFORMANCE_OUTPUT=/absolute/path/to/results \
  swift test -c release --filter PerformanceTests
```

这些 opt-in 测试在普通 `swift test` 中跳过，涵盖最大鱼群的真实 Metal 绘制、真实音频反复加载与 seek、歌词批量导入、统计查询，以及复制真实元数据到 1000／5000／10000 条的排序缓存测试。组件基准不等于完整窗口的 CPU、耗电或输入延迟；元数据扩展不代表同规模真实文件扫描。歌词与数据库仅在内存副本中修改。
