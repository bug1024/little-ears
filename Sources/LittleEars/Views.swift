import SwiftUI
import Charts
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) var scheme
    @AppStorage("appearance") var appearance = "system"
    @AppStorage("accent") var accent = "blue"
    @AppStorage("spectrumEnabled") var spectrumEnabled = true
    @Environment(\.openSettings) var openSettings
    @State private var deletingPlaylist: Playlist?
    var persistSidebarWidth = true
    var palette: Palette { Palette(dark: scheme == .dark, accentName: accent) }
    var body: some View {
        GeometryReader { geometry in
            HSplitView {
                sidebar
                    .frame(minWidth: 196, idealWidth: 196, maxWidth: min(360, max(196, geometry.size.width - 620)))
                    .background(SplitViewAutosave(enabled: persistSidebarWidth))
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
        }.background(palette.background).foregroundStyle(palette.text).tint(palette.accent)
            .font(.system(size: 12)).controlSize(.small).buttonStyle(.bordered)
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
            .frame(minWidth: 900, minHeight: 600)
            .onAppear { model.setSpectrumWindowVisible(true); model.setSpectrumEnabled(spectrumEnabled) }
            .onDisappear { model.setSpectrumWindowVisible(false) }
            .onChange(of: spectrumEnabled) { _, value in model.setSpectrumEnabled(value) }
            .alert("删除「\(deletingPlaylist?.name ?? "")」？", isPresented: Binding(get: { deletingPlaylist != nil }, set: { if !$0 { deletingPlaylist = nil } })) {
                Button("取消", role: .cancel) { deletingPlaylist = nil }
                Button("删除", role: .destructive) {
                    guard let playlist = deletingPlaylist else { return }
                    deletingPlaylist = nil
                    Task {
                        do { try await model.deletePlaylist(playlist) }
                        catch { model.errorMessage = error.localizedDescription }
                    }
                }
            } message: { Text("只删除播放列表，原始音频、播放记录和当前队列都会保留。") }
            .sheet(item: $model.listeningDayTarget) { day in DailyListeningDetailsView(day: day).environmentObject(model).environment(\.colorScheme, scheme) }
            .sheet(item: $model.trackDetailsTarget) { target in TrackStatisticsView(target: target).environmentObject(model).environment(\.colorScheme, scheme) }
            .sheet(item: $model.playlistDraft) { draft in PlaylistNameSheet(draft: draft).environmentObject(model).environment(\.colorScheme, scheme) }
            .alert("Little Ears", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("知道了", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "ear.badge.waveform").font(.system(size: 20, weight: .regular)).foregroundStyle(palette.accent)
                Text("Little Ears").font(.system(size: 15, weight: .semibold))
            }.padding(.horizontal, 16).frame(height: 57)
            VStack(spacing: 2) {
                nav("音乐库", icon: "square.stack", page: "library", count: model.tracks.count)
                nav("播放列表", icon: "music.note.list", page: "playlists", count: model.playlists.count)
                nav("正在播放", icon: "play.circle", page: "playing", count: nil)
                nav("播放统计", icon: "chart.bar.xaxis", page: "stats", count: nil)
            }.padding(.horizontal, 9)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel("播放列表") { model.draftPlaylist() }
                    if model.playlists.isEmpty {
                        Text("创建列表，保存播放顺序").font(.system(size: 10)).foregroundStyle(palette.tertiary).padding(.horizontal, 8).padding(.bottom, 6)
                    }
                    ForEach(model.playlists) { playlist in
                        Button { model.selectedPlaylistID = playlist.id; model.page = "playlists" } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "music.note.list").font(.system(size: 11)).foregroundStyle(palette.secondary)
                                Text(playlist.name).lineLimit(1).font(.system(size: 11))
                                Spacer(minLength: 0)
                                Text("\(model.items(in: playlist.id).count)").font(.system(size: 10)).foregroundStyle(palette.tertiary)
                            }.padding(.horizontal, 8).frame(height: 29).contentShape(Rectangle())
                                .modifier(SelectionSurface(palette: palette, selected: model.page == "playlists" && model.selectedPlaylist?.id == playlist.id))
                        }.buttonStyle(.plain).modifier(HoverHighlight()).help("\(playlist.name) · 拖动调整列表顺序，右键重命名或删除")
                            .contextMenu {
                                Button("重命名…") { model.playlistDraft = PlaylistDraft(playlistID: playlist.id, name: playlist.name) }
                                Button("删除播放列表…", role: .destructive) { deletingPlaylist = playlist }
                            }
                            .onDrag { NSItemProvider(object: ("little-ears-playlist:" + playlist.id) as NSString) }
                            .onDrop(of: [.text], isTargeted: nil) { providers in
                                guard !model.savingPlaylists, let provider = providers.first else { return false }
                                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                                    guard let payload = object as? String, payload.hasPrefix("little-ears-playlist:") else { return }
                                    let id = String(payload.dropFirst("little-ears-playlist:".count))
                                    Task { @MainActor in
                                        guard let from = model.playlists.firstIndex(where: { $0.id == id }), let to = model.playlists.firstIndex(where: { $0.id == playlist.id }), from != to else { return }
                                        do { try await model.movePlaylists(from: IndexSet(integer: from), to: from < to ? to + 1 : to) }
                                        catch { model.errorMessage = error.localizedDescription }
                                    }
                                }
                                return true
                            }
                    }
                    sectionLabel("音乐目录", action: model.importFolders)
                    ForEach(model.sources) { source in FolderBranch(source: source, path: "", palette: palette) }
                    if model.sources.isEmpty { Text("添加本地音频文件夹").font(.system(size: 10)).foregroundStyle(palette.tertiary).padding(.horizontal, 8) }
                }.padding(.horizontal, 9)
            }
            HStack(spacing: 6) {
                Circle().fill(model.isPlaying ? palette.accent : palette.tertiary).frame(width: 4, height: 4)
                Text(model.isPlaying ? "正在播放 · 本地音频" : "本地音频 · 离线音乐库").font(.system(size: 10)).foregroundStyle(palette.secondary)
                Spacer(minLength: 0)
                Button { openSettings() } label: { Image(systemName: "gearshape").font(.system(size: 12)) }.buttonStyle(.bordered).help("设置 · ⌘,")
            }.padding(.horizontal, 12).frame(height: 38).overlay(alignment: .top) { Rectangle().fill(palette.border).frame(height: 1) }
        }.background(LinearGradient(colors: [palette.elevated.opacity(0.5), palette.sidebar, palette.background], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
    private func sectionLabel(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.secondary)
            Spacer()
            Button(action: action) { Image(systemName: "plus").font(.system(size: 10)) }.buttonStyle(.bordered).disabled(!model.ready || model.scanning || model.savingPlaylists).help(title == "播放列表" ? "新建播放列表" : "添加目录")
        }.padding(.leading, 8).padding(.top, 13).padding(.bottom, 3)
    }
    private func nav(_ title: String, icon: String, page: String, count: Int?) -> some View {
        Button {
            model.page = page
            if page == "library" { model.selectedFolder = nil }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13, weight: .regular)).frame(width: 18)
                Text(title).font(.system(size: 12, weight: model.page == page ? .medium : .regular))
                Spacer()
                if let count { Text("\(count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(palette.secondary) }
            }.padding(.horizontal, 9).frame(height: 31).contentShape(Rectangle())
                .foregroundStyle(model.page == page ? palette.text : palette.secondary)
                .modifier(SelectionSurface(palette: palette, selected: model.page == page))
        }.buttonStyle(.plain).modifier(HoverHighlight())
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold)).frame(width: 10, height: 26).contentShape(Rectangle()) }.buttonStyle(.plain).opacity(children.isEmpty ? 0 : 1).disabled(children.isEmpty)
                Button {
                    model.selectedFolder = "\(source.id)|\(path)"; model.page = "library"; model.search = ""
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: path.isEmpty ? "folder.fill" : "folder").font(.system(size: 11)).foregroundStyle(palette.secondary)
                        Text(path.isEmpty ? source.name : (path as NSString).lastPathComponent).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 0)
                    }.frame(height: 27).contentShape(Rectangle())
                }.buttonStyle(.plain).help(path.isEmpty ? source.name : path)
            }.padding(.horizontal, 5)
                .modifier(SelectionSurface(palette: palette, selected: model.selectedFolder == "\(source.id)|\(path)" && model.page == "library", radius: 5))
                .modifier(HoverHighlight())
                .contextMenu { Button("刷新目录") { model.refreshAll() }; Button("重新授权目录…") { model.reauthorize(source) } }
            if expanded { ForEach(children, id: \.self) { child in FolderBranch(source: source, path: child, palette: palette).padding(.leading, 10) } }
        }
    }
}
struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    let palette: Palette
    @State private var selection = Set<String>()
    var body: some View {
        let visible = model.visibleTracks
        let selectedIDs = selection.isEmpty ? [] : visible.filter { selection.contains($0.id) }.map(\.id)
        return VStack(spacing: 0) {
            PageHeader(title: model.folderTitle, detail: "\(visible.count) 首 · \(listeningLabel(visible.reduce(0) { $0 + $1.duration }))", palette: palette) {
                if model.scanning { ProgressView().controlSize(.mini) }
                Button(action: model.importFolders) { Label("添加目录", systemImage: "folder.badge.plus") }.disabled(!model.ready || model.scanning)
            }
            if model.tracks.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "folder.badge.plus").font(.system(size: 32, weight: .light)).foregroundStyle(palette.secondary)
                    Text("添加你的音乐目录").font(.system(size: 17, weight: .medium))
                    Text("音频保留在原处，支持 MP3、M4A、WAV、AIFF、CAF 和 FLAC。")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                    Button("选择文件夹…", action: model.importFolders).buttonStyle(.borderedProminent).disabled(!model.ready || model.scanning)
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 10) {
                    Button { model.start(selectedIDs.isEmpty ? visible : visible.filter { selection.contains($0.id) }) } label: { Label(selectedIDs.isEmpty ? "播放" : "播放所选", systemImage: "play.fill") }.disabled(visible.isEmpty)
                    AddToPlaylistMenu(trackIDs: selectedIDs).menuStyle(.borderlessButton).fixedSize()
                    Button(action: model.refreshAll) { Image(systemName: "arrow.clockwise") }.buttonStyle(.bordered).help("刷新音乐库").disabled(model.scanning)
                    if model.selectedFolder != nil { Toggle("子目录", isOn: $model.includeChildren).toggleStyle(.checkbox).font(.system(size: 11)) }
                    Spacer(minLength: 6)
                    Picker("排序", selection: $model.sortByDuration) { Text("名称").tag(false); Text("时长").tag(true) }.labelsHidden().frame(width: 77)
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass").foregroundStyle(palette.secondary)
                        TextField("搜索音频", text: $model.search).textFieldStyle(.plain)
                        if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(palette.tertiary) }.buttonStyle(.plain).help("清除搜索") }
                    }.padding(.horizontal, 8).frame(width: 152, height: 28).modifier(MaterialSurface(palette: palette, radius: 7, inset: true))
                }.font(.system(size: 11)).padding(.horizontal, 20).frame(height: 42)
                TableColumnHeader(palette: palette).padding(.horizontal, 20)
                List(selection: $selection) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, track in
                        TrackTableRow(palette: palette, index: index, title: track.title,
                                      origin: track.available ? (track.folder.isEmpty ? model.sources.first { $0.id == track.sourceID }?.name ?? "" : track.folder) : "文件不可用",
                                      duration: track.duration, format: track.format, current: model.currentTrack?.id == track.id, selected: selection.contains(track.id))
                            .tag(track.id).listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                }.contextMenu(forSelectionType: String.self) { ids in
                    let targets = visible.filter { ids.contains($0.id) }
                    Button(ids.count > 1 ? "播放所选音频" : "播放") {
                        if targets.count > 1 { model.start(targets) }
                        else if let track = targets.first { model.start(visible, at: track) }
                    }.disabled(targets.isEmpty)
                    AddToPlaylistMenu(trackIDs: targets.map(\.id))
                    if targets.count == 1, let track = targets.first {
                        Button("查看收听统计") { model.showTrackStatistics(track.id) }
                        Button("在 Finder 中显示") { model.reveal(track) }
                    }
                } primaryAction: { ids in
                    if let track = visible.first(where: { ids.contains($0.id) }) { model.start(visible, at: track) }
                }.listStyle(.plain).scrollContentBackground(.hidden).contentMargins(.horizontal, 0, for: .scrollContent)
                    .modifier(MaterialSurface(palette: palette, radius: 9, inset: true)).padding(.horizontal, 12).padding(.bottom, 8)
                HStack {
                    Text(selectedIDs.isEmpty ? "⌘ 点击多选 · Shift 连选" : "已选择 \(selectedIDs.count) 首")
                    Button(selection.isEmpty ? "全选" : "取消选择") {
                        selection = selection.isEmpty ? Set(visible.map(\.id)) : []
                    }.buttonStyle(.plain).foregroundStyle(palette.accent).disabled(visible.isEmpty)
                    Spacer()
                    Text(model.scanning ? "正在扫描…" : "\(model.sources.count) 个音乐目录")
                }.font(.system(size: 10)).foregroundStyle(palette.secondary).padding(.horizontal, 20).frame(height: 27)
                    .overlay(alignment: .top) { Rectangle().fill(palette.border).frame(height: 1) }
            }
        }.onChange(of: visible.map(\.id)) { _, ids in selection.formIntersection(ids) }
    }
}
struct PlaybackProgress: View {
    @EnvironmentObject var model: AppModel
    let palette: Palette
    var body: some View {
        SeekControl(display: model.playbackPosition, duration: model.currentTrack?.duration, palette: palette, seek: model.seek)
    }
}
private struct SeekControl: View {
    @ObservedObject var display: PlaybackPositionDisplay
    let duration: Double?
    let palette: Palette
    let seek: (Double) -> Void
    @State private var dragging = false
    @State private var scrub: Double = 0
    var body: some View {
        VStack(spacing: 1) {
            MaterialSlider(value: Binding(get: { dragging ? scrub : min(display.position, max(1, duration ?? 1)) }, set: { scrub = $0 }), range: 0...max(1, duration ?? 1), palette: palette) { editing in
                dragging = editing
                if editing { scrub = display.position } else { seek(scrub) }
            }.frame(height: 18).disabled(duration == nil).accessibilityLabel("播放进度")
            HStack { Text(timeLabel(dragging ? scrub : display.position)); Spacer(); Text(timeLabel(duration ?? 0)) }
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary)
        }
    }
}
struct PlayerBar: View {
    @EnvironmentObject var model: AppModel
    let palette: Palette
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 16) {
                Button { model.page = "playing" } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "music.note").font(.system(size: 14)).foregroundStyle(palette.secondary).frame(width: 32, height: 32).modifier(MaterialSurface(palette: palette, radius: 7, inset: true))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.currentTrack?.title ?? "未选择音频").font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(model.currentTrack.map { $0.folder.isEmpty ? "本地音频" : ($0.folder as NSString).lastPathComponent } ?? "从音乐库开始播放")
                                .font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }.buttonStyle(.plain).frame(width: max(154, min(220, proxy.size.width * 0.24))).help("显示正在播放")
                HStack(spacing: 8) {
                    Button(action: model.previous) { Image(systemName: "backward.end.fill").font(.system(size: 11)).frame(width: 28, height: 28) }.buttonStyle(InstrumentButtonStyle(circular: true)).help("上一首 · ⌘←")
                    Button(action: model.togglePlayback) {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .semibold)).offset(x: model.isPlaying ? 0 : 1).frame(width: 38, height: 38)
                    }.buttonStyle(InstrumentButtonStyle(prominent: true, circular: true)).help("播放／暂停 · ⌘P").accessibilityLabel(model.isPlaying ? "暂停" : "播放")
                    Button(action: model.next) { Image(systemName: "forward.end.fill").font(.system(size: 11)).frame(width: 28, height: 28) }.buttonStyle(InstrumentButtonStyle(circular: true)).help("下一首 · ⌘→")
                }.disabled(!model.ready || (model.currentTrack == nil && model.visibleTracks.isEmpty))
                if model.page == "playing" { Spacer(minLength: 0) }
                else { PlaybackProgress(palette: palette).frame(maxWidth: .infinity) }
                HStack(spacing: 9) {
                    SleepTimerButton(timer: model.sleepTimer, palette: palette, hasTrack: model.currentTrack != nil)
                    Button(action: model.cycleMode) { Image(systemName: model.mode.symbol).font(.system(size: 12)).foregroundStyle(model.mode == .sequential ? palette.secondary : palette.accent) }.buttonStyle(InstrumentButtonStyle(compact: true)).help(model.mode.title)
                    Image(systemName: model.volume == 0 ? "speaker.slash" : "speaker.wave.2").font(.system(size: 10)).foregroundStyle(palette.secondary)
                    MaterialSlider(value: Binding(get: { Double(model.volume) }, set: { model.volume = Float($0) }), range: 0...1, palette: palette).frame(width: model.page == "playing" ? 110 : 60, height: 18).accessibilityLabel("音量")
                }
            }.padding(.horizontal, 18).frame(height: 68)
        }.frame(height: 68).background(LinearGradient(colors: [palette.surface, palette.background], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(palette.dark ? 0.07 : 0.9)).frame(height: 1) }
    }
}
struct SpectrumPlot: View {
    var preferences = SpectrumPreferences()
    @ObservedObject var display: SpectrumDisplay
    let palette: Palette
    let playing: Bool
    var body: some View {
        Canvas { context, size in
            let baseline = size.height * 0.82
            let plotHeight = max(1, baseline - 8)
            let step = size.width / CGFloat(max(1, display.frame.levels.count))
            var bars = Path()
            for (index, level) in display.frame.levels.enumerated() {
                let height = max(1, CGFloat(min(1, Double(level) * preferences.amplitude)) * plotHeight)
                let rect = CGRect(x: CGFloat(index) * step + 1.2, y: baseline - height, width: max(1, step - 2.4), height: height)
                bars.addRoundedRect(in: rect, cornerSize: CGSize(width: 2, height: 2))
            }
            if palette.dark && preferences.glow {
                var light = context
                light.addFilter(.blur(radius: 8))
                light.fill(bars, with: .color(palette.accent.opacity(playing ? 0.16 : 0.08)))
            }
            context.fill(bars, with: .linearGradient(Gradient(colors: [palette.accent.opacity(palette.dark ? 0.95 : 0.9), palette.accent.opacity(palette.dark ? 0.45 : 0.55)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: baseline)))
            for (index, level) in display.frame.levels.enumerated() {
                let x = CGFloat(index) * step + 1.2
                let reflection = CGRect(x: x, y: baseline + 3, width: max(1, step - 2.4), height: CGFloat(min(1, Double(level) * preferences.amplitude)) * plotHeight * 0.14)
                if preferences.reflection { context.fill(Path(reflection), with: .linearGradient(Gradient(colors: [palette.accent.opacity(palette.dark ? 0.18 : 0.06), .clear]), startPoint: CGPoint(x: x, y: baseline), endPoint: CGPoint(x: x, y: reflection.maxY))) }
                if preferences.peaks && index < display.frame.peaks.count {
                    let peak = CGFloat(min(1, Double(display.frame.peaks[index]) * preferences.amplitude)) * plotHeight
                    if peak > 3 {
                        context.fill(Path(CGRect(x: x, y: baseline - peak - 3, width: max(1, step - 2.4), height: 1)), with: .color(palette.accent.opacity(0.7)))
                    }
                }
            }
            var line = Path(); line.move(to: CGPoint(x: 0, y: baseline + 1)); line.addLine(to: CGPoint(x: size.width, y: baseline + 1))
            context.stroke(line, with: .color(palette.accent.opacity(0.08)), lineWidth: 0.5)
        }.accessibilityLabel("实时音频频谱").accessibilityValue(playing ? "正在显示播放音频的频谱" : "已暂停")
    }
}
struct NowPlayingView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("spectrumEnabled") var spectrumEnabled = true
    @AppStorage("playingVisualization") var visualization = "spectrum"
    var spectrumPreferences = SpectrumPreferences()
    @State private var showingSpectrumSettings = false
    @State private var showingAquariumSettings = false
    let palette: Palette
    @State private var draggedID: String?
    @State private var showingInfo = false
    var currentIndex: Int? { model.queue.firstIndex { $0.id == model.currentID } }
    private var playbackColor: Color { model.isPlaying ? palette.accent : palette.secondary }
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "正在播放", detail: model.currentTrack?.format ?? "", palette: palette) {
                Text(model.mode.title).font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        Picker("播放画面", selection: $visualization) {
                            Text("频谱").tag("spectrum"); Text("水族箱").tag("aquarium")
                        }.labelsHidden().pickerStyle(.segmented).controlSize(.mini)
                            .frame(width: 132).accessibilityLabel("播放画面")
                        if visualization == "aquarium" {
                            AquariumAmbientButton(controller: model.aquarium)
                                .font(.system(size: 10)).controlSize(.mini)
                        } else {
                            Button { spectrumEnabled.toggle() } label: {
                                Label(spectrumEnabled ? "频谱已开启" : "频谱已关闭", systemImage: "waveform")
                            }
                            .font(.system(size: 10)).controlSize(.mini)
                            .help(spectrumEnabled ? "关闭实时音频频谱" : "开启实时音频频谱")
                            .accessibilityLabel("实时音频频谱")
                            .accessibilityValue(spectrumEnabled ? "已开启" : "已关闭")
                        }
                        Spacer()
                        Circle().fill(playbackColor).frame(width: 5, height: 5)
                        Text(visualization == "aquarium" ? "轻松聆听" : model.currentTrack == nil ? "待播放" : spectrumEnabled ? (model.isPlaying ? "实时" : "已暂停") : "频谱已关闭").font(.system(size: 10)).foregroundStyle(palette.secondary)
                        if visualization == "aquarium" {
                            Button { model.aquariumImmersive = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                                .help("沉浸全屏 · Esc 退出").accessibilityLabel("水族箱沉浸全屏")
                            Button { showingAquariumSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                                .help("水族箱场景配置").accessibilityLabel("水族箱场景配置")
                        } else {
                            Button { showingSpectrumSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                                .help("频谱配置").accessibilityLabel("频谱配置")
                        }
                    }.padding(.bottom, 8)
                    if visualization == "aquarium" {
                        AquariumSurface(controller: model.aquarium, musicPlaying: model.isPlaying)
                            .frame(minHeight: 160, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if model.currentTrack == nil {
                        VStack(spacing: 14) {
                            Image(systemName: "ear.badge.waveform").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(palette.secondary.opacity(0.5))
                            Button("前往音乐库") { model.page = "library" }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if spectrumEnabled {
                        Group {
                            if spectrumPreferences.style == "fluid" {
                                FluidSpectrumPlot(display: model.spectrumDisplay, palette: palette, amplitude: spectrumPreferences.amplitude, layers: spectrumPreferences.layerCount, glow: spectrumPreferences.glow)
                            } else {
                                SpectrumPlot(display: model.spectrumDisplay, palette: palette, playing: model.isPlaying)
                            }
                        }
                            .frame(minHeight: 160, maxHeight: .infinity)
                            .background { RadialGradient(colors: [palette.accent.opacity(palette.dark ? 0.055 : 0.025), .clear], center: .center, startRadius: 0, endRadius: 260) }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "waveform").font(.system(size: 28, weight: .light))
                            Text("可通过上方开关开启实时频谱").font(.system(size: 11))
                        }.foregroundStyle(palette.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    PlaybackProgress(palette: palette).padding(.top, 4).padding(.bottom, 12)
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Circle().fill(playbackColor).frame(width: 4, height: 4)
                                Text(model.isPlaying ? "正在播放" : "当前音频").font(.system(size: 10, weight: .medium)).foregroundStyle(playbackColor)
                            }
                            Text(model.currentTrack?.title ?? "未选择音频").font(.system(size: 26, weight: .semibold)).lineLimit(2)
                            Text(model.currentTrack?.folder ?? "从音乐库选择音频开始播放").font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let track = model.currentTrack {
                            Button { showingInfo.toggle() } label: { FormatBadge(title: track.format, palette: palette) }
                                .buttonStyle(.plain).help("音频信息").accessibilityLabel("音频信息")
                                .popover(isPresented: $showingInfo) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(track.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                        LabeledContent("时长", value: timeLabel(track.duration))
                                        LabeledContent("文件大小", value: ByteCountFormatter.string(fromByteCount: track.fileSize, countStyle: .file))
                                        LabeledContent("队列位置", value: currentIndex.map { "\($0 + 1) / \(model.queue.count)" } ?? "—")
                                    }.font(.system(size: 11)).padding(18).frame(width: 280).foregroundStyle(palette.text).background(palette.surface)
                                }
                        }
                    }
                }.padding(22).modifier(MaterialSurface(palette: palette, radius: 16, inset: true)).padding(16).frame(maxWidth: .infinity)
                Rectangle().fill(palette.border).frame(width: 1)
                queuePanel.frame(width: 264).background(LinearGradient(colors: [palette.surface.opacity(0.55), palette.background], startPoint: .top, endPoint: .bottom))
            }
        }.onAppear { model.setSpectrumVisible(visualization == "spectrum") }
            .onDisappear { model.setSpectrumVisible(false) }
            .onChange(of: visualization) { _, value in model.setSpectrumVisible(value == "spectrum") }
            .sheet(isPresented: $showingSpectrumSettings) { SpectrumSettingsPanel() }
            .sheet(isPresented: $showingAquariumSettings) { AquariumSettingsPanel(controller: model.aquarium) }
    }
    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("播放队列").font(.system(size: 12, weight: .semibold))
                Text("\(model.queue.count)").font(.system(size: 10)).foregroundStyle(palette.secondary)
                Spacer()
                SaveQueueMenu().labelStyle(.iconOnly).help("保存队列到播放列表")
            }.padding(.horizontal, 14).frame(height: 42)
                .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, item in
                        let track = model.tracks.first { $0.id == item.trackID }
                        HStack(spacing: 9) {
                            Text(String(format: "%02d", index + 1))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(item.id == model.currentID ? playbackColor : palette.tertiary)
                                .frame(width: 19)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(track?.title ?? "音频不可用").font(.system(size: 11, weight: item.id == model.currentID ? .medium : .regular)).lineLimit(1)
                                Text(track.map { ($0.folder as NSString).lastPathComponent } ?? "文件不可用").font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if item.id == model.currentID {
                                Image(systemName: model.isPlaying ? "waveform" : "pause.fill")
                                    .font(.system(size: 10)).foregroundStyle(playbackColor)
                                    .accessibilityLabel(model.isPlaying ? "正在播放" : "当前音频，已暂停")
                            }
                            Text(timeLabel(track?.duration ?? 0)).font(.system(size: 10)).monospacedDigit().foregroundStyle(palette.secondary)
                        }.padding(.horizontal, 10).frame(height: 52)
                            .background {
                                if item.id == model.currentID {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(model.isPlaying ? palette.accent.opacity(palette.dark ? 0.09 : 0.08) : palette.elevated.opacity(0.45))
                                        .allowsHitTesting(false)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if item.id != model.currentID && index + 1 < model.queue.count && model.queue[index + 1].id != model.currentID {
                                    Rectangle().fill(palette.border.opacity(0.65)).frame(height: 0.5).padding(.leading, 38).padding(.trailing, 10).allowsHitTesting(false)
                                }
                            }
                            .overlay(alignment: .leading) {
                                if item.id == model.currentID {
                                    RoundedRectangle(cornerRadius: 1).fill(playbackColor.opacity(0.8)).frame(width: 2).padding(.vertical, 12).allowsHitTesting(false)
                                }
                            }
                            .help(track.map { "\($0.title) · \($0.folder)" } ?? "音频不可用")
                            .contentShape(Rectangle()).modifier(HoverHighlight()).onTapGesture(count: 2) { model.jump(item) }
                            .contextMenu { Button("从这里播放") { model.jump(item) } }
                            .onDrag { draggedID = item.id; return NSItemProvider(object: item.id as NSString) }
                            .onDrop(of: [.text], isTargeted: nil) { _ in
                                guard let draggedID, let from = model.queue.firstIndex(where: { $0.id == draggedID }), let to = model.queue.firstIndex(where: { $0.id == item.id }), from != to else { return false }
                                model.moveQueue(from: IndexSet(integer: from), to: from < to ? to + 1 : to); self.draggedID = nil; return true
                            }
                    }
                }.padding(.horizontal, 8).padding(.vertical, 6)
                if model.queue.isEmpty { Text("队列为空").font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, 28) }
            }
            Text("拖拽排序 · 双击播放").font(.system(size: 9)).foregroundStyle(palette.tertiary).padding(.horizontal, 14).frame(height: 28)
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
        VStack(spacing: 0) {
            PageHeader(title: "播放统计", detail: Date().formatted(.dateTime.month().day()), palette: palette) { Text("实际播放记录").font(.system(size: 11)).foregroundStyle(palette.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 0) {
                        stat("今日时长", value: listeningLabel(total(since: Calendar.current.startOfDay(for: Date()))))
                        Rectangle().fill(palette.border).frame(width: 1).padding(.vertical, 16)
                        stat("本周时长", value: listeningLabel(total(since: weekStart)))
                        Rectangle().fill(palette.border).frame(width: 1).padding(.vertical, 16)
                        stat("本月时长", value: listeningLabel(total(since: Calendar.current.dateInterval(of: .month, for: Date())!.start)))
                        Rectangle().fill(palette.border).frame(width: 1).padding(.vertical, 16)
                        stat("完整播放", value: "\(model.stats.completions) 次")
                    }.frame(height: 78).modifier(PanelStyle(palette: palette))
                    ListeningFootprintView(palette: palette)
                    VStack(alignment: .leading, spacing: 15) {
                        HStack { Text("最近 7 天").font(.system(size: 12, weight: .medium)); Spacer(); Text("分钟").font(.system(size: 10)).foregroundStyle(palette.secondary) }
                        Chart(days) { day in BarMark(x: .value("日期", String(day.day.suffix(5))), y: .value("分钟", day.seconds / 60)).foregroundStyle(palette.accent.opacity(0.7)).cornerRadius(2) }
                            .chartYScale(domain: 0...max(1, (days.map { $0.seconds / 60 }.max() ?? 0) * 1.2)).chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)); AxisValueLabel().font(.system(size: 9)) } }
                            .frame(height: 142)
                        if days.allSatisfy({ $0.seconds == 0 }) { Text("播放音频后显示每日时长").font(.system(size: 10)).foregroundStyle(palette.secondary) }
                    }.padding(16).modifier(PanelStyle(palette: palette))
                    VStack(spacing: 0) {
                        HStack { Text("常听音频").font(.system(size: 12, weight: .medium)); Spacer(); Text("按累计时长排序").font(.system(size: 10)).foregroundStyle(palette.secondary) }.padding(.bottom, 10)
                        HStack { Text("#").frame(width: 26, alignment: .leading); Text("名称"); Spacer(); Text("完整播放").frame(width: 80, alignment: .trailing); Text("累计时长").frame(width: 125, alignment: .trailing) }
                            .font(.system(size: 10)).foregroundStyle(palette.secondary).frame(height: 27).overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
                        if model.stats.tracks.isEmpty { Text("暂无播放记录").font(.system(size: 11)).foregroundStyle(palette.secondary).frame(maxWidth: .infinity).frame(height: 60) }
                        ForEach(Array(model.stats.tracks.prefix(20).enumerated()), id: \.element.trackID) { index, item in
                            Button { model.showTrackStatistics(item.trackID) } label: {
                              HStack {
                                Text(String(format: "%02d", index + 1)).font(.system(size: 10)).monospacedDigit().foregroundStyle(palette.tertiary).frame(width: 26, alignment: .leading)
                                Text(model.tracks.first { $0.id == item.trackID }?.title ?? "历史音频").font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                Text("\(item.completions)").frame(width: 80, alignment: .trailing)
                                Text(listeningLabel(item.seconds)).frame(width: 125, alignment: .trailing)
                              }.font(.system(size: 11)).monospacedDigit().frame(height: 32).background(index.isMultiple(of: 2) ? palette.surface.opacity(0.5) : .clear).contentShape(Rectangle())
                            }.buttonStyle(.plain).modifier(HoverHighlight()).help("查看收听统计")
                        }
                    }.padding(16).modifier(PanelStyle(palette: palette))
                }.padding(20)
            }
        }
    }
    var weekStart: Date { var calendar = Calendar.current; calendar.firstWeekday = 2; return calendar.dateInterval(of: .weekOfYear, for: Date())!.start }
    private func stat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 10)).foregroundStyle(palette.secondary)
            Text(value).font(.system(size: 21, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 17)
    }
}
struct SettingsView: View {
    @Environment(\.colorScheme) var scheme
    @AppStorage("appearance") var appearance = "system"
    @AppStorage("accent") var accent = "blue"
    var palette: Palette { Palette(dark: scheme == .dark, accentName: accent) }
    let accents = [("blue", "冰川蓝"), ("mint", "薄荷绿"), ("lavender", "薰衣草紫"), ("coral", "暖珊瑚")]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "ear.badge.waveform").font(.system(size: 23)).foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Little Ears").font(.system(size: 15, weight: .semibold))
                    Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.5.0") · 本地音频播放器").font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
                Spacer()
            }.frame(height: 36)
            VStack(alignment: .leading, spacing: 12) {
                Text("外观").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.secondary)
                HStack {
                    Text("主题")
                    Spacer()
                    Picker("主题", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }.labelsHidden().pickerStyle(.segmented).frame(width: 260)
                }
                HStack(spacing: 8) {
                    Text("强调色")
                    Spacer()
                    ForEach(accents, id: \.0) { name, title in
                        let color = Palette(dark: scheme == .dark, accentName: name).accent
                        Button { accent = name } label: {
                            Circle().fill(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                                .overlay { if accent == name { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(scheme == .dark ? Color.black.opacity(0.75) : .white) } }
                                .padding(3).overlay(Circle().stroke(accent == name ? color.opacity(0.7) : .clear, lineWidth: 1))
                        }.buttonStyle(.plain).help(title).accessibilityLabel(title).accessibilityValue(accent == name ? "已选择" : "")
                    }
                }
            }.padding(16).modifier(PanelStyle(palette: palette))
            Text("引用本地文件，不复制或修改原始音频。播放队列与统计自动保存。")
                .font(.system(size: 11)).foregroundStyle(palette.secondary).lineSpacing(3)
            Spacer(minLength: 0)
        }.font(.system(size: 12)).foregroundStyle(palette.text).padding(22).frame(width: 490, height: 300)
            .background(LinearGradient(colors: [palette.sidebar, palette.background], startPoint: .topLeading, endPoint: .bottomTrailing))
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light).tint(palette.accent)
    }
}
