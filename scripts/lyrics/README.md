# 歌词处理脚本

这些工具独立于 Little Ears 应用，用于准备和检查本地歌词文件。应用只导入本地文件，不调用 LRCLIB。应用内的匹配与覆盖规则见 [功能实现说明](../../docs/FEATURES.md#本地歌词)。

## 环境与入口

在仓库根目录执行，使用 Python 3.10 或更新版本；查询和时长检查需要 `ffprobe` 在 PATH 中。繁转简工具使用 macOS Foundation 和 Swift。

```sh
python3 -I scripts/lyrics/fetch_lyrics.py --help
python3 -I scripts/lyrics/fetch_lyrics.py --root /path/to/music --dry-run
python3 -I scripts/lyrics/fetch_lyrics.py --root /path/to/music
python3 -I scripts/lyrics/verify.py /path/to/music
```

`-I` 启用 Python 隔离模式。`--root` 应指向已有音乐目录，脚本没有为不存在的根目录单独报错。

## 查询与写入

`fetch_lyrics.py` 从音频标签及文件名生成标题和歌手查询，访问 [LRCLIB](https://lrclib.net) 的 `/api/search`，再以 `/api/get` 兜底。它不会导入应用资料库；运行后需在应用中批量导入生成的文件。

- 输出与音频同目录、同文件名的 `.lrc`；同一文件名的不同音频格式共用侧边歌词文件。同步歌词优先，只有纯文本时也以 `.lrc` 保存，应用可作为无时间轴文本读取。
- `[ar:]`、`[ti:]`、`[al:]` 使用音频自身的非空标签，正文中的原元数据行会被移除；缺失标签不自动补写文件名。
- 默认保留已有 `.lrc`；`--force` 允许覆盖，不自动备份。保留检查发生在查询之后，因此已有文件仍可能触发联网。
- `--dry-run` 不写歌词文件，但仍会联网并写缓存；指定 `--report` 时也会写 JSON 报告。
- `--cache` 默认指向被 Git 忽略的 `scripts/lyrics/cache/`。缓存保存成功响应与 404，其他错误不缓存；成功响应可能包含完整歌词。命中缓存的查询不重新请求，额外查询及未缓存失败仍可能联网。
- `--jobs` 默认 4。脚本有请求间隔和重试退避，但没有跨线程统一限流或读取 `Retry-After` 的逻辑。

查询接口的在线可用性不能由代码保证。错误应与无结果区分；搜索无结果也不能证明服务中不存在该歌曲。

## 候选选择与人工核对

每次查询内部按元组排序：时间轴非空、时长差档位、时间戳单调性、检测到的繁体字符数量、时长差、标题和歌手一致性。通常排除时长差超过 5 秒的候选；元数据缺失时长时无法按此规则获得正常候选。

返回首个携带歌词的查询结果后即停止，不跨所有查询统一择优。标题、歌手只作为排序因素，未严格验证版本、专辑或歌曲身份；时间轴字段非空也不代表已通过应用解析。因此需核对输出候选及实际播放时间轴，不能将写入成功视为正确匹配。

`--report /path/to/report.json` 保存逐曲结果与统计，不保存歌词正文。`--overrides /path/to/overrides.json` 显式加载按音乐目录相对路径登记的人工查询规则；仓库中的 `overrides.json` 不会默认加载。`ignore_duration` 可绕过时长检查；它不校准时间轴。非 `ignore_duration` 分支目前未传入本地时长，可能回退到人工候选选择，不能视为严格的时长筛选。

## 繁转简

先自行备份，再运行：

```sh
swift scripts/lyrics/convert_hant.swift /path/to/music .lyrics-hant-backup
```

工具递归处理 UTF-8 `.lrc`，通过 macOS ICU `Hant-Hans` 转换后原地写入。第二个参数是要跳过的**目录名**，不是备份输出路径；工具不会创建备份。时间戳等 ASCII 内容不变，中文正文和标签会转换；ICU 的字符转换不保证符合每句歌词的语义。输出包含转换、未变化和失败数量。

## 文件检查

`verify.py` 按音频文件查找同目录同名的小写 `.lrc`，统计缺失、时间轴和纯文本，报告空内容、非 UTF-8、BOM、CRLF、时间戳顺序及明显超过音频时长等问题。它跳过 `.lyrics-hant-backup` 目录，不修改文件。

这只是辅助检查，不与应用解析器完全等价：不验证所有时间数值范围，不应用 LRC offset，也不检查歌词与歌曲内容是否一致。BOM 和 CRLF 会被脚本报告，但应用可以正常读取。脚本打印问题后不会以非零状态退出，不能直接作为 CI 的通过判据。
