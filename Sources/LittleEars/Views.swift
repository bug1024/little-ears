import SwiftUI
import Charts
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) var scheme
    @AppStorage("appearance") var appearance = "system"
    @AppStorage("accent") var accent = "blue"
    @Environment(\.openSettings) var openSettings
    var palette: Palette { Palette(dark: scheme == .dark, accentName: accent) }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Rectangle().fill(palette.border).frame(width: 1)
            VStack(spacing: 0) {
                Group {
                    switch model.page {
                    case "playing": NowPlayingView(palette: palette)
                    case "playlists": PlaylistsView(palette: palette)
                    case "stats": StatisticsView(palette: palette)
                    default: LibraryView(palette: palette)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(palette.border).frame(height: 1)
                PlayerBar(palette: palette)
            }
        }
        .background(palette.background).foregroundStyle(palette.text).tint(palette.accent)
        .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
        .frame(minWidth: 920, minHeight: 620)
        .sheet(item: $model.playlistDraft) { draft in PlaylistNameSheet(draft: draft).environmentObject(model) }
        .alert("Little Ears", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "ear.badge.waveform").font(.system(size: 24, weight: .medium)).foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Little Ears").font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text("每天一点，慢慢听见").font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
            }.padding(.top, 26).padding(.bottom, 30).padding(.horizontal, 20)
            VStack(spacing: 5) {
                nav("音乐库", icon: "square.stack", page: "library")
                nav("播放列表", icon: "music.note.list", page: "playlists")
                nav("正在播放", icon: "play.circle", page: "playing")
                nav("播放统计", icon: "chart.bar.xaxis", page: "stats")
            }.padding(.horizontal, 12)
            if !model.playlists.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("我的播放列表").font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.secondary).padding(.horizontal, 9)
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(model.playlists) { playlist in
                                Button { model.selectedPlaylistID = playlist.id; model.page = "playlists" } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "music.note.list").foregroundStyle(palette.accent)
                                        Text(playlist.name).lineLimit(1); Spacer(minLength: 0)
                                    }.font(.system(size: 12)).padding(9)
                                        .background(model.page == "playlists" && model.selectedPlaylist?.id == playlist.id ? palette.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(maxHeight: 130)
                }.padding(.horizontal, 12).padding(.top, 22)
            }
            HStack {
                Text("音乐目录").font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.secondary)
                Spacer()
                Button(action: model.importFolders) { Image(systemName: "plus").font(.system(size: 12)) }.buttonStyle(.plain).help("添加音频目录").disabled(!model.ready || model.scanning)
            }.padding(.horizontal, 21).padding(.top, 32).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.sources) { source in
                        FolderBranch(source: source, path: "", palette: palette)
                    }
                    if model.sources.isEmpty {
                        Text("添加一个文件夹，\n让故事从这里开始。").font(.system(size: 12)).foregroundStyle(palette.secondary).lineSpacing(5).padding(.horizontal, 9)
                    }
                }.padding(.horizontal, 12)
            }
            Spacer(minLength: 10)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 7) {
                    Circle().fill(palette.accent).frame(width: 5, height: 5)
                    Text("本地音频 · 完全离线").font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
                Button { openSettings() } label: { Label("设置", systemImage: "gearshape").font(.system(size: 12)) }.buttonStyle(.plain)
            }.padding(22)
        }.background(palette.surface.opacity(0.55))
    }
    private func nav(_ title: String, icon: String, page: String) -> some View {
        Button {
            model.page = page
            if page == "library" { model.selectedFolder = nil }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 20)
                Text(title).font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                Spacer()
                if page == "library" { Text("\(model.tracks.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary) }
            }.padding(.horizontal, 12).padding(.vertical, 11)
                .foregroundStyle(model.page == page ? palette.accent : palette.secondary)
                .background(model.page == page ? palette.accent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
}
struct FolderBranch: View {
    @EnvironmentObject var model: AppModel
    let source: LibrarySource
    let path: String
    let palette: Palette
    @State private var expanded = true
    var children: [String] {
        let prefix = path.isEmpty ? "" : path + "/"
        return Set(model.tracks.filter { $0.sourceID == source.id }.compactMap { track -> String? in
            guard track.folder.hasPrefix(prefix) else { return nil }
            let remainder = String(track.folder.dropFirst(prefix.count))
            guard let first = remainder.split(separator: "/").first else { return nil }
            return prefix + first
        }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).frame(width: 10)
                }.buttonStyle(.plain).opacity(children.isEmpty ? 0 : 1).disabled(children.isEmpty)
                Button {
                    model.selectedFolder = "\(source.id)|\(path)"; model.page = "library"; model.search = ""
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: path.isEmpty ? "folder.fill" : "folder").font(.system(size: 12)).foregroundStyle(palette.accent.opacity(0.8))
                        Text(path.isEmpty ? source.name : (path as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 0)
                    }.padding(.vertical, 7)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 6)
                .background(model.selectedFolder == "\(source.id)|\(path)" ? palette.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contextMenu {
                    Button("刷新目录") { model.refreshAll() }
                    Button("重新授权目录…") { model.reauthorize(source) }
                }
            if expanded { ForEach(children, id: \.self) { child in FolderBranch(source: source, path: child, palette: palette).padding(.leading, 12) } }
        }
    }
}
struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    let palette: Palette
    @State private var selection = Set<String>()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("YOUR LISTENING SPACE").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(palette.secondary)
                    Text(model.folderTitle).font(.system(size: 29, weight: .semibold))
                    Text(model.scanning ? "正在读取音频信息…" : "\(model.visibleTracks.count) 段音频 · \(listeningLabel(model.visibleTracks.reduce(0) { $0 + $1.duration }))")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary)
                }
                Spacer()
                Button(action: model.importFolders) { Label("添加目录", systemImage: "folder.badge.plus") }.disabled(!model.ready || model.scanning)
                    .buttonStyle(.bordered).controlSize(.large)
            }.padding(.bottom, 26)
            if model.tracks.isEmpty {
                Spacer()
                VStack(spacing: 19) {
                    ListeningArtwork(palette: palette, size: 148)
                    Text("把熟悉的故事，放进每天。").font(.system(size: 23, weight: .medium))
                    Text("选择你的英文故事、儿歌或分级阅读目录。\n音频留在原处，Little Ears 帮你接着听。")
                        .font(.system(size: 13)).foregroundStyle(palette.secondary).multilineTextAlignment(.center).lineSpacing(6)
                    Button(action: model.importFolders) { Label("选择音频文件夹", systemImage: "plus").padding(.horizontal, 10).padding(.vertical, 5) }
                        .buttonStyle(.borderedProminent).disabled(!model.ready || model.scanning)
                }.frame(maxWidth: .infinity)
                Spacer()
                Text("支持 MP3、M4A、WAV、AIFF、CAF 与 FLAC").font(.system(size: 10)).foregroundStyle(palette.secondary).frame(maxWidth: .infinity).padding(.bottom, 26)
            } else {
                HStack(spacing: 12) {
                    Button { model.start(model.visibleTracks) } label: { Label("播放全部", systemImage: "play.fill") }.buttonStyle(.borderedProminent).disabled(model.visibleTracks.isEmpty)
                    Button(action: model.refreshAll) { Image(systemName: "arrow.clockwise") }.buttonStyle(.bordered).help("刷新音乐库").disabled(model.scanning)
                    AddToPlaylistMenu(trackIDs: model.visibleTracks.filter { selection.contains($0.id) }.map(\.id))
                        .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
                    if model.selectedFolder != nil { Toggle("包含子目录", isOn: $model.includeChildren).toggleStyle(.checkbox).font(.system(size: 11)) }
                    Spacer()
                }.padding(.bottom, 12)
                HStack {
                    Text(selection.isEmpty ? "按 ⌘ 或 Shift 多选歌曲" : "已选择 \(model.visibleTracks.filter { selection.contains($0.id) }.count) 首")
                        .font(.system(size: 10)).foregroundStyle(palette.secondary)
                    Spacer()
                    Picker("排序", selection: $model.sortByDuration) { Text("名称").tag(false); Text("时长").tag(true) }.labelsHidden().frame(width: 90)
                    HStack(spacing: 7) { Image(systemName: "magnifyingglass").foregroundStyle(palette.secondary); TextField("搜索音频", text: $model.search).textFieldStyle(.plain) }
                        .font(.system(size: 12)).padding(9).frame(width: 190).background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
                }.padding(.bottom, 19)
                HStack {
                    Text("音频"); Spacer(); Text("时长").frame(width: 65); Text("格式").frame(width: 55)
                }.font(.system(size: 10)).foregroundStyle(palette.secondary).padding(.horizontal, 14).padding(.bottom, 10)
                Rectangle().fill(palette.border).frame(height: 1)
                List(selection: $selection) {
                    ForEach(model.visibleTracks) { track in
                        trackRow(track).tag(track.id).listRowSeparator(.hidden).listRowBackground(Color.clear)
                            .onTapGesture(count: 2) { model.start(model.visibleTracks, at: track) }
                            .contextMenu {
                                Button("播放") { model.start(model.visibleTracks, at: track) }
                                Button("播放所选音频") { model.start(model.visibleTracks.filter { selection.contains($0.id) }) }.disabled(selection.isEmpty)
                                AddToPlaylistMenu(trackIDs: selection.contains(track.id) ? model.visibleTracks.filter { selection.contains($0.id) }.map(\.id) : [track.id])
                                Button("在 Finder 中显示") { model.reveal(track) }
                            }
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
                if model.visibleTracks.isEmpty { Text("没有匹配的音频。试试其他目录或搜索词。").font(.system(size: 12)).foregroundStyle(palette.secondary).padding(20) }
            }
        }.padding(.horizontal, 32).padding(.top, 32)
    }
    private func trackRow(_ track: Track) -> some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(palette.elevated).frame(width: 38, height: 38)
                Image(systemName: model.currentTrack?.id == track.id ? "speaker.wave.2.fill" : "music.note").font(.system(size: 14)).foregroundStyle(model.currentTrack?.id == track.id ? palette.accent : palette.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(track.available ? (track.folder.isEmpty ? model.sources.first { $0.id == track.sourceID }?.name ?? "" : track.folder) : "文件不可用 · 刷新目录以重新检查")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
            }
            Spacer()
            Text(timeLabel(track.duration)).monospacedDigit().frame(width: 65)
            Text(track.format).font(.system(size: 9, design: .monospaced)).frame(width: 55)
        }.foregroundStyle(palette.text).padding(.vertical, 7)
    }
}
struct ListeningArtwork: View {
    let palette: Palette
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [palette.accent.opacity(0.12), palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
            ForEach(0..<4) { i in Circle().stroke(palette.accent.opacity(0.08 + Double(i) * 0.025), lineWidth: 1).padding(CGFloat(i) * size * 0.09 + 9) }
            Image(systemName: "ear.badge.waveform").font(.system(size: size * 0.28, weight: .ultraLight)).foregroundStyle(palette.accent)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
struct PlayerBar: View {
    @EnvironmentObject var model: AppModel
    let palette: Palette
    @State private var dragging = false
    @State private var scrub: Double = 0
    var body: some View {
        VStack(spacing: 13) {
            HStack(spacing: 20) {
                HStack(spacing: 11) {
                    Image(systemName: "music.note").font(.system(size: 20)).foregroundStyle(palette.accent).frame(width: 42, height: 42).background(palette.elevated, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.currentTrack?.title ?? "还没有开始播放").font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(model.currentTrack.map { $0.folder.isEmpty ? "本地音频" : ($0.folder as NSString).lastPathComponent } ?? "选一段故事，开始今天的熏听")
                            .font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 13) {
                    Button(action: model.previous) { Image(systemName: "backward.end.fill") }.help("上一首 · ⌘←")
                    Button(action: model.togglePlayback) {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 17, weight: .semibold)).offset(x: model.isPlaying ? 0 : 1)
                            .foregroundStyle(palette.background).frame(width: 44, height: 44).background(palette.accent, in: Circle())
                    }.buttonStyle(.plain).help("播放／暂停 · ⌘P").accessibilityLabel(model.isPlaying ? "暂停" : "播放")
                    Button(action: model.next) { Image(systemName: "forward.end.fill") }.help("下一首 · ⌘→")
                }.buttonStyle(QuietButtonStyle()).disabled(!model.ready)
                HStack(spacing: 8) {
                    Button(action: model.cycleMode) { Image(systemName: model.mode.symbol).foregroundStyle(model.mode == .sequential ? palette.secondary : palette.accent) }.help(model.mode.title).buttonStyle(QuietButtonStyle())
                    Image(systemName: model.volume == 0 ? "speaker.slash" : "speaker.wave.2").font(.system(size: 11)).foregroundStyle(palette.secondary)
                    Slider(value: $model.volume, in: 0...1).frame(width: 80).controlSize(.small).accessibilityLabel("音量")
                }.frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Text(timeLabel(dragging ? scrub : model.position)).frame(width: 44, alignment: .trailing)
                Slider(value: Binding(get: { dragging ? scrub : min(model.position, max(1, model.currentTrack?.duration ?? 1)) }, set: { scrub = $0 }), in: 0...max(1, model.currentTrack?.duration ?? 1)) { editing in
                    dragging = editing
                    if editing { scrub = model.position } else { model.seek(scrub) }
                }.controlSize(.small).disabled(model.currentTrack == nil).accessibilityLabel("播放进度")
                Text(timeLabel(model.currentTrack?.duration ?? 0)).frame(width: 44, alignment: .leading)
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary)
        }.padding(.horizontal, 24).padding(.vertical, 17).background(palette.surface)
    }
}
struct NowPlayingView: View {
    @EnvironmentObject var model: AppModel
    let palette: Palette
    @State private var draggedID: String?
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack { Text("NOW PLAYING").font(.system(size: 9, design: .monospaced)).tracking(2); Spacer(); Text(model.isPlaying ? "正在播放" : "已暂停").font(.system(size: 11)) }
                    .foregroundStyle(palette.secondary)
                Spacer()
                ListeningArtwork(palette: palette, size: 230)
                Text(model.currentTrack?.title ?? "故事即将开始").font(.system(size: 27, weight: .medium)).multilineTextAlignment(.center).lineLimit(3).padding(.top, 30)
                Text(model.currentTrack.map { $0.folder.isEmpty ? "本地音频" : $0.folder } ?? "从音乐库选择你想听的音频")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.top, 10)
                Spacer()
                Text(model.mode.title).font(.system(size: 11)).foregroundStyle(palette.accent).padding(.bottom, 12)
            }.padding(32).frame(maxWidth: .infinity)
            Rectangle().fill(palette.border).frame(width: 1)
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("接下来听").font(.system(size: 17, weight: .semibold)); Spacer(); Text("\(model.queue.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.secondary) }
                Text("当前队列 · 拖拽调整播放顺序").font(.system(size: 10)).foregroundStyle(palette.secondary)
                SaveQueueMenu()
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, item in
                            let track = model.tracks.first { $0.id == item.trackID }
                            HStack(spacing: 12) {
                                Text(String(format: "%02d", index + 1)).font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary).frame(width: 20)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(track?.title ?? "音频不可用").font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    Text(track.map { ($0.folder as NSString).lastPathComponent } ?? "").font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if item.id == model.currentID { Image(systemName: model.isPlaying ? "speaker.wave.2.fill" : "pause.fill").font(.system(size: 11)).foregroundStyle(palette.accent) }
                                else { Text(timeLabel(track?.duration ?? 0)).font(.system(size: 9, design: .monospaced)).foregroundStyle(palette.secondary) }
                            }.padding(13).background(item.id == model.currentID ? palette.accent.opacity(0.1) : palette.surface, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(item.id == model.currentID ? palette.accent.opacity(0.4) : palette.border, lineWidth: 1))
                                .contentShape(Rectangle()).onTapGesture(count: 2) { model.jump(item) }
                                .contextMenu { Button("从这里播放") { model.jump(item) } }
                                .onDrag { draggedID = item.id; return NSItemProvider(object: item.id as NSString) }
                                .onDrop(of: [.text], isTargeted: nil) { _ in
                                    guard let draggedID, let from = model.queue.firstIndex(where: { $0.id == draggedID }), let to = model.queue.firstIndex(where: { $0.id == item.id }), from != to else { return false }
                                    model.moveQueue(from: IndexSet(integer: from), to: from < to ? to + 1 : to); self.draggedID = nil; return true
                                }
                        }
                    }
                    if model.queue.isEmpty { Text("播放音频后，队列会显示在这里。").font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.top, 40) }
                }
            }.padding(24).frame(width: 300).background(palette.surface.opacity(0.3))
        }
    }
}
struct StatisticsView: View {
    @EnvironmentObject var model: AppModel
    let palette: Palette
    var days: [DailyStat] {
        (0..<7).reversed().map { offset in
            let day = ListeningClock.day(Calendar.current.date(byAdding: .day, value: -offset, to: Date())!)
            return DailyStat(day: day, seconds: model.stats.days.first { $0.day == day }?.seconds ?? 0)
        }
    }
    func total(since: Date) -> Double { let key = ListeningClock.day(since); return model.stats.days.filter { $0.day >= key }.reduce(0) { $0 + $1.seconds } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A LITTLE, EVERY DAY").font(.system(size: 9, design: .monospaced)).tracking(2).foregroundStyle(palette.secondary)
                    Text("听见日积月累").font(.system(size: 29, weight: .semibold))
                    Text("每一段真实播放，都在这里留下记录。").font(.system(size: 12)).foregroundStyle(palette.secondary)
                }
                HStack(spacing: 12) {
                    statCard("今日熏听", value: listeningLabel(total(since: Calendar.current.startOfDay(for: Date()))), icon: "sun.max")
                    statCard("本周熏听", value: listeningLabel(total(since: weekStart)), icon: "calendar")
                    statCard("本月熏听", value: listeningLabel(total(since: Calendar.current.dateInterval(of: .month, for: Date())!.start)), icon: "clock")
                    statCard("完整播放", value: "\(model.stats.completions) 次", icon: "checkmark.circle")
                }
                VStack(alignment: .leading, spacing: 22) {
                    HStack { Text("最近 7 天").font(.system(size: 15, weight: .semibold)); Spacer(); Text("实际播放时长 / 分钟").font(.system(size: 10)).foregroundStyle(palette.secondary) }
                    Chart(days) { day in BarMark(x: .value("日期", String(day.day.suffix(5))), y: .value("分钟", day.seconds / 60)).foregroundStyle(palette.accent).cornerRadius(4) }
                        .chartYScale(domain: 0...max(1, (days.map { $0.seconds / 60 }.max() ?? 0) * 1.2)).frame(height: 170)
                    if days.allSatisfy({ $0.seconds == 0 }) { Text("开始播放后，这里会显示你的真实熏听记录。").font(.system(size: 11)).foregroundStyle(palette.secondary) }
                }.padding(22).background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
                Text("常听的音频").font(.system(size: 17, weight: .semibold))
                if model.stats.tracks.isEmpty {
                    Text("还没有播放记录。每天一点，慢慢积累。").font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.vertical, 15)
                } else {
                    ForEach(Array(model.stats.tracks.prefix(10).enumerated()), id: \.element.trackID) { index, stat in
                        HStack(spacing: 16) {
                            Text(String(format: "%02d", index + 1)).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.secondary)
                            Text(model.tracks.first { $0.id == stat.trackID }?.title ?? "历史音频").font(.system(size: 13)).lineLimit(1)
                            Spacer()
                            Text("\(stat.completions) 次完整播放").font(.system(size: 11)).foregroundStyle(palette.secondary)
                            Text(listeningLabel(stat.seconds)).font(.system(size: 12, weight: .medium)).frame(width: 110, alignment: .trailing)
                        }.padding(15).background(palette.surface, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }.padding(32)
        }
    }
    var weekStart: Date {
        var calendar = Calendar.current; calendar.firstWeekday = 2
        return calendar.dateInterval(of: .weekOfYear, for: Date())!.start
    }
    func statCard(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack { Text(title).font(.system(size: 11)); Spacer(); Image(systemName: icon).foregroundStyle(palette.accent) }.foregroundStyle(palette.secondary)
            Text(value).font(.system(size: 18, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(palette.surface, in: RoundedRectangle(cornerRadius: 11))
    }
}
struct SettingsView: View {
    @AppStorage("appearance") var appearance = "system"
    @AppStorage("accent") var accent = "blue"
    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $appearance) { Text("跟随系统").tag("system"); Text("深色").tag("dark"); Text("浅色").tag("light") }
                Picker("强调色", selection: $accent) { Text("冰川蓝").tag("blue"); Text("薄荷绿").tag("mint"); Text("薰衣草紫").tag("lavender"); Text("暖珊瑚").tag("coral") }
            }
            Section("关于 Little Ears") {
                Text("本地音频，完全离线。原始文件不会被复制或修改。").font(.callout)
                Text("完整播放：自然结束并覆盖至少 90% 的音频内容。播放记录每 5 秒保存；重启后保持暂停。").font(.caption).foregroundStyle(.secondary)
                Text("Little Ears 0.2 · 音乐库 / 播放列表 / 播放统计").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(12).frame(width: 440, height: 310)
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
    }
}
