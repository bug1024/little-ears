import SwiftUI

struct LyricsPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var library: LyricsLibrary
    let palette: Palette
    @State private var showManager = false
    var roots: [String: String] { Dictionary(uniqueKeysWithValues: model.sources.map { ($0.id, $0.path) }) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("歌词").font(.system(size: 12, weight: .semibold))
                Spacer()
                if library.importing { ProgressView().controlSize(.mini) }
                Menu {
                    Button("为当前音频导入…") { library.chooseImport(target: model.currentTrack, tracks: model.tracks, roots: roots) { showManager = true } }.disabled(model.currentTrack == nil)
                    Button("批量导入歌词…") { batchImport() }
                    Button("管理歌词匹配…") { showManager = true }
                    if let track = model.currentTrack, let record = library.record(for: track.id) {
                        Divider()
                        Button("解除当前关联") { Task { do { try await library.associate(record, with: nil) } catch { library.message = error.localizedDescription; showManager = true } } }
                    }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().help("导入与管理歌词")
            }.padding(.horizontal, 14).frame(height: 38)
            Rectangle().fill(palette.border).frame(height: 1)
            if let track = model.currentTrack, let record = library.record(for: track.id) {
                LyricReadingView(document: library.document(for: record), position: model.playbackPosition, palette: palette, seek: model.seek)
                    .id(track.id + record.id)
                Text(record.filename).font(.system(size: 9)).foregroundStyle(palette.tertiary).lineLimit(1).help(record.filename).padding(.horizontal, 14).frame(height: 28)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "text.alignleft").font(.system(size: 24, weight: .light)).foregroundStyle(palette.tertiary)
                    Text(model.currentTrack == nil ? "选择音频后查看歌词" : "这首音频尚未关联歌词").font(.system(size: 11)).foregroundStyle(palette.secondary)
                    Button("导入当前歌词…") { library.chooseImport(target: model.currentTrack, tracks: model.tracks, roots: roots) { showManager = true } }.disabled(model.currentTrack == nil || !model.ready || library.importing)
                    Button("批量导入…") { batchImport() }.disabled(!model.ready || library.importing)
                    if !library.records.isEmpty { Button("从已导入歌词中关联…") { showManager = true } }
                    Spacer()
                }.padding(14).frame(maxWidth: .infinity)
            }
        }.sheet(isPresented: $showManager) { LyricsManagerView(library: library, palette: palette).environmentObject(model) }
    }
    private func batchImport() { library.chooseImport(target: nil, tracks: model.tracks, roots: roots) { showManager = true } }
}

struct LyricReadingView: View {
    let document: LyricDocument
    @ObservedObject var position: PlaybackPositionDisplay
    let palette: Palette
    let seek: (Double) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var follow = true
    private var active: Int? { document.activeLine(at: position.position) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(document.timed ? "时间轴歌词" : "纯文本").font(.system(size: 9)).foregroundStyle(palette.tertiary)
                Spacer()
                if document.timed { Toggle("跟随播放", isOn: $follow).toggleStyle(.checkbox).font(.system(size: 10)) }
            }.padding(.horizontal, 14).frame(height: 32)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(document.lines) { line in
                            Group {
                                if let time = line.time {
                                    Button { seek(time) } label: {
                                        Text(line.text.isEmpty ? "♪" : line.text)
                                            .font(.system(size: 14, weight: line.id == active ? .semibold : .regular))
                                            .foregroundStyle(line.id == active ? palette.accent : palette.secondary)
                                            .lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 10).contentShape(Rectangle())
                                    }.buttonStyle(.plain).help("跳转到 \(timeLabel(time))")
                                } else {
                                    Text(line.text).font(.system(size: 13)).foregroundStyle(palette.text).lineSpacing(5).textSelection(.enabled).padding(.vertical, 6)
                                }
                            }.id(line.id)
                        }
                    }.padding(.horizontal, 18).padding(.vertical, 22)
                }
                .onAppear { if follow, let active { proxy.scrollTo(active, anchor: .center) } }
                .onChange(of: active) { _, value in
                    if follow, let value {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { proxy.scrollTo(value, anchor: .center) }
                    }
                }
                .onChange(of: follow) { _, value in if value, let active { proxy.scrollTo(active, anchor: .center) } }
            }
        }
    }
}

struct LyricsManagerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: LyricsLibrary
    let palette: Palette
    @State private var pendingOnly = true
    @State private var assigning: LyricRecord?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("歌词导入与匹配").font(.title3.weight(.semibold)); Spacer(); if library.importing { ProgressView().controlSize(.small) } }
            if let message = library.message { Text(message).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(5).textSelection(.enabled) }
            HStack {
                Toggle("仅显示待关联", isOn: $pendingOnly).toggleStyle(.checkbox)
                Spacer()
                Text("\(library.records.filter { $0.trackID != nil }.count) 已关联 · \(library.records.filter { $0.trackID == nil }.count) 待关联").foregroundStyle(palette.secondary)
            }.font(.system(size: 11))
            List {
                ForEach(library.records.filter { !pendingOnly || $0.trackID == nil }) { record in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.filename).lineLimit(1).help(record.sourcePath)
                            if let id = record.trackID, let track = model.tracks.first(where: { $0.id == id }) {
                                Text("已关联：" + model.displayName(track)).foregroundStyle(palette.secondary).lineLimit(1)
                            } else {
                                let candidates = LyricMatching.candidates(record, tracks: model.tracks, roots: Dictionary(uniqueKeysWithValues: model.sources.map { ($0.id, $0.path) }))
                                Text(candidates.isEmpty ? "未找到匹配曲目" : candidates.count > 1 ? "多个候选（\(candidates.count) 首），请手动选择" : "候选曲目已有歌词或存在重复候选，请手动关联").foregroundStyle(palette.secondary).lineLimit(2)
                            }
                        }.font(.system(size: 11))
                        Spacer()
                        Button(record.trackID == nil ? "关联…" : "更改…") { assigning = record }
                        if record.trackID != nil {
                            Button("解除") { Task { do { try await library.associate(record, with: nil) } catch { library.message = error.localizedDescription } } }
                        }
                    }.padding(.vertical, 5)
                }
            }.overlay {
                if library.records.filter({ !pendingOnly || $0.trackID == nil }).isEmpty {
                    Text(library.records.isEmpty ? "尚未导入歌词" : "没有待关联歌词").foregroundStyle(palette.secondary).font(.system(size: 12))
                }
            }
            HStack {
                Button("继续导入…") {
                    library.chooseImport(target: nil, tracks: model.tracks, roots: Dictionary(uniqueKeysWithValues: model.sources.map { ($0.id, $0.path) })) {}
                }.disabled(library.importing || !model.ready)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 620, height: 460).foregroundStyle(palette.text).background(palette.background)
            .sheet(item: $assigning) { record in LyricAssignmentView(record: record, library: library, palette: palette).environmentObject(model) }
    }
}
struct LyricAssignmentView: View {
    let record: LyricRecord
    @ObservedObject var library: LyricsLibrary
    let palette: Palette
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selection: String?
    @State private var saving = false
    @State private var error: String?
    private var replacing: Bool { selection.flatMap { library.record(for: $0) }.map { $0.id != record.id } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("关联歌词").font(.title3.weight(.semibold))
            Text(record.filename).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
            TextField("搜索标题或文件名", text: $search).textFieldStyle(.roundedBorder)
            List(selection: $selection) {
                ForEach(model.tracks.filter { $0.matchesName(search) }.sorted { model.displayName($0).localizedStandardCompare(model.displayName($1)) == .orderedAscending }) { track in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.displayName(track)).lineLimit(1)
                        Text(track.relativePath).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                    }.tag(track.id)
                }
            }
            if replacing { Text("将替换该曲当前关联的歌词，原歌词仍保留在导入记录中。").font(.caption).foregroundStyle(palette.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(replacing ? "替换并关联" : "关联") {
                    guard let selection else { return }; saving = true
                    Task {
                        do { try await library.associate(record, with: selection); dismiss() }
                        catch { self.error = error.localizedDescription; saving = false }
                    }
                }.keyboardShortcut(.defaultAction).disabled(selection == nil || saving)
            }
        }.padding(20).frame(width: 500, height: 420).foregroundStyle(palette.text).background(palette.background)
    }
}

/// A glanceable lyric beside the track information; the sidebar remains the reader.
struct CompactLyricsView: View {
    @ObservedObject var library: LyricsLibrary
    @ObservedObject var position: PlaybackPositionDisplay
    let trackID: String
    let palette: Palette
    let openLyrics: () -> Void
    var body: some View {
        Button(action: openLyrics) {
            Group {
                if let record = library.record(for: trackID) {
                    let document = library.document(for: record)
                    if document.timed {
                        let active = document.activeLine(at: position.position)
                        let current = active.map { document.lines[$0].text }.flatMap { $0.isEmpty ? nil : $0 } ?? "♪"
                        let next = (active.map { $0 + 1 } ?? 0)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(current).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.accent).lineLimit(2)
                            if document.lines.indices.contains(next) {
                                Text(document.lines[next].text).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                            }
                        }
                    } else {
                        Label("查看歌词全文", systemImage: "text.alignleft").font(.system(size: 11)).foregroundStyle(palette.secondary)
                    }
                } else {
                    Label("添加歌词", systemImage: "text.badge.plus").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain).modifier(HoverHighlight()).help("展开右侧歌词面板")
    }
}
